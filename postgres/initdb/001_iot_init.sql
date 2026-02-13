CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS plant (
  plant_id      TEXT PRIMARY KEY,
  plant_name    TEXT NOT NULL,
  longitude     NUMERIC(9,6),
  latitude      NUMERIC(8,6),
  timezone      TEXT NOT NULL DEFAULT 'Asia/Shanghai',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT plant_longitude_chk CHECK (longitude BETWEEN -180 AND 180),
  CONSTRAINT plant_latitude_chk CHECK (latitude BETWEEN -90 AND 90)
);

CREATE TABLE IF NOT EXISTS point (
  point_id      TEXT PRIMARY KEY,
  plant_id      TEXT NOT NULL REFERENCES plant(plant_id) ON DELETE CASCADE,
  point_type    TEXT NOT NULL CHECK (point_type IN ('inlet', 'outlet')),
  point_name    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS device (
  device_id              TEXT PRIMARY KEY,
  point_id               TEXT NOT NULL REFERENCES point(point_id) ON DELETE RESTRICT,
  report_interval_sec    INT NOT NULL DEFAULT 60 CHECK (report_interval_sec BETWEEN 1 AND 3600),
  align_mode             TEXT NOT NULL DEFAULT 'floor' CHECK (align_mode IN ('round', 'floor')),
  enabled                BOOLEAN NOT NULL DEFAULT true,
  last_seen_at           TIMESTAMPTZ,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS metric_dict (
  metric        TEXT PRIMARY KEY,
  display_name  TEXT NOT NULL,
  unit          TEXT,
  visible       BOOLEAN NOT NULL DEFAULT true,
  alarm_low     DOUBLE PRECISION,
  alarm_high    DOUBLE PRECISION,
  CONSTRAINT metric_dict_alarm_range_chk CHECK (
    alarm_low IS NULL OR alarm_high IS NULL OR alarm_low <= alarm_high
  )
);

ALTER TABLE metric_dict
  ADD COLUMN IF NOT EXISTS visible BOOLEAN NOT NULL DEFAULT true;

-- Baseline thresholds:
-- - GB 3838-2002 (III class): pH 6~9, DO >= 5 mg/L, COD <= 20 mg/L, NH3-N <= 1.0 mg/L
-- - GB 18918-2002 (Class 1-A): SS <= 10 mg/L
-- - Remaining indicators use conservative engineering ranges for device/sensor health alerts.
INSERT INTO metric_dict(metric, display_name, unit, visible, alarm_low, alarm_high)
SELECT s.metric, s.display_name, s.unit, s.visible, s.alarm_low, s.alarm_high
FROM (
  VALUES
    ('watetT', '水温', '°C', true, 0::double precision, 35::double precision),
    ('waterEC', '电导率', 'uS/cm', true, 50::double precision, 2000::double precision),
    ('amnitro', '氨氮', 'mg/L', true, 0::double precision, 1.0::double precision),
    ('ph', '酸碱度', 'pH', true, 6::double precision, 9::double precision),
    ('dissolvedOxygen', '溶解氧', 'mg/L', true, 5::double precision, 14.6::double precision),
    ('turbidity', '浊度', 'NTU', true, 0::double precision, 10::double precision),
    ('cod', '化学需氧量', 'mg/L', true, 0::double precision, 20::double precision),
    ('ss', '悬浮物浓度', 'mg/L', true, 0::double precision, 10::double precision),
    ('temperature', '水温2', '°C', true, -20::double precision, 60::double precision)
) AS s(metric, display_name, unit, visible, alarm_low, alarm_high)
WHERE NOT EXISTS (SELECT 1 FROM metric_dict);

CREATE TABLE IF NOT EXISTS raw_message (
  raw_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ingest_ts     TIMESTAMPTZ NOT NULL DEFAULT now(),
  topic         TEXT NOT NULL,
  msg_id        TEXT NOT NULL,
  payload       JSONB NOT NULL
);



CREATE INDEX IF NOT EXISTS raw_message_ts_idx
  ON raw_message (ingest_ts DESC);

CREATE INDEX IF NOT EXISTS raw_message_topic_ts_idx
  ON raw_message (topic, ingest_ts DESC);

CREATE INDEX IF NOT EXISTS raw_message_topic_msg_idx
  ON raw_message (topic, msg_id, ingest_ts DESC);

CREATE TABLE IF NOT EXISTS metric_sample (
  ingest_ts                TIMESTAMPTZ NOT NULL,
  plant_id                 TEXT NOT NULL,
  point_id                 TEXT NOT NULL,
  device_id                TEXT NOT NULL,
  metric                   TEXT NOT NULL,
  value_num                DOUBLE PRECISION NOT NULL,
  raw_id                   BIGINT
);

-- Non-backward-compatible cleanup: keep only canonical fields and raw_id joinback.
ALTER TABLE metric_sample DROP COLUMN IF EXISTS unit;
ALTER TABLE metric_sample DROP COLUMN IF EXISTS interval_sec_snapshot;
ALTER TABLE metric_sample DROP COLUMN IF EXISTS align_mode_snapshot;
ALTER TABLE metric_sample DROP COLUMN IF EXISTS msg_id;
ALTER TABLE metric_sample DROP COLUMN IF EXISTS topic;

SELECT create_hypertable(
  'metric_sample',
  'ingest_ts',
  chunk_time_interval => INTERVAL '1 day',
  if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS metric_sample_point_metric_ts_idx
  ON metric_sample (point_id, metric, ingest_ts DESC);

CREATE INDEX IF NOT EXISTS metric_sample_device_metric_ts_idx
  ON metric_sample (device_id, metric, ingest_ts DESC);

CREATE INDEX IF NOT EXISTS metric_sample_raw_id_idx
  ON metric_sample (raw_id, ingest_ts DESC);

CREATE INDEX IF NOT EXISTS metric_sample_plant_metric_ts_idx
  ON metric_sample (plant_id, metric, ingest_ts DESC);

CREATE INDEX IF NOT EXISTS metric_sample_plant_metric_point_ts_idx
  ON metric_sample (plant_id, metric, point_id, ingest_ts DESC);

DROP FUNCTION IF EXISTS ingest_telemetry(TEXT, JSONB, TEXT, SMALLINT);
DROP FUNCTION IF EXISTS ingest_telemetry(TEXT, JSONB, TEXT, INT);
CREATE OR REPLACE FUNCTION ingest_telemetry(
  p_topic TEXT,
  p_payload JSONB,
  p_clientid TEXT,
  p_qos INT
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  parts TEXT[];
  v_plant_id TEXT;
  v_point_id TEXT;
  v_device_id TEXT;
  v_msg_id TEXT;
  v_raw_id BIGINT;
  v_ingest_ts TIMESTAMPTZ;
  v_report_interval_sec INT;
  v_align_mode TEXT;
  v_aligned_ts TIMESTAMPTZ;
  v_epoch DOUBLE PRECISION;
  metric_kv RECORD;
  v_value DOUBLE PRECISION;
BEGIN
  parts := regexp_split_to_array(p_topic, '/');
  IF array_length(parts, 1) <> 6
     OR parts[1] <> 'water'
     OR parts[2] <> 'v1'
     OR parts[6] <> 'telemetry' THEN
    RAISE EXCEPTION 'invalid topic: %', p_topic;
  END IF;

  v_plant_id := parts[3];
  v_point_id := parts[4];
  v_device_id := parts[5];

  IF v_device_id <> p_clientid THEN
    RAISE EXCEPTION 'device_id(%) != clientid(%)', v_device_id, p_clientid;
  END IF;

  IF jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'payload must be a flat json object';
  END IF;

  IF p_payload ? 'metrics' OR p_payload ? 'msg_id' OR p_payload ? 'seq' THEN
    RAISE EXCEPTION 'legacy payload is not supported: metrics/msg_id/seq are forbidden';
  END IF;

  IF (SELECT count(*) FROM jsonb_object_keys(p_payload)) = 0 THEN
    RAISE EXCEPTION 'payload must contain at least one metric';
  END IF;

  SELECT d.report_interval_sec, d.align_mode
  INTO v_report_interval_sec, v_align_mode
  FROM device d
  JOIN point p ON p.point_id = d.point_id
  WHERE d.device_id = v_device_id
    AND d.enabled = true
    AND d.point_id = v_point_id
    AND p.plant_id = v_plant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'device not found/enabled or topic path mismatch: %', p_topic;
  END IF;

  v_msg_id := md5(clock_timestamp()::text || random()::text || p_topic || p_payload::text);

  INSERT INTO raw_message(
    topic, msg_id, payload
  ) VALUES (
    p_topic, v_msg_id, p_payload
  )
  RETURNING raw_id, ingest_ts INTO v_raw_id, v_ingest_ts;

  -- Keep raw_message.ingest_ts untouched, and align only metric_sample.ingest_ts.
  v_report_interval_sec := GREATEST(1, COALESCE(v_report_interval_sec, 60));
  v_align_mode := COALESCE(v_align_mode, 'floor');
  v_epoch := extract(epoch FROM v_ingest_ts);
  IF v_align_mode = 'round' THEN
    v_aligned_ts := to_timestamp(
      floor((v_epoch / v_report_interval_sec::DOUBLE PRECISION) + 0.5) * v_report_interval_sec
    );
  ELSE
    v_aligned_ts := to_timestamp(
      floor(v_epoch / v_report_interval_sec::DOUBLE PRECISION) * v_report_interval_sec
    );
  END IF;

  FOR metric_kv IN
    SELECT key, value
    FROM jsonb_each(p_payload)
  LOOP
    BEGIN
      v_value := (metric_kv.value #>> '{}')::DOUBLE PRECISION;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'payload value must be numeric: key=% value=%', metric_kv.key, metric_kv.value;
    END;

    INSERT INTO metric_sample(
      ingest_ts, plant_id, point_id, device_id,
      metric, value_num, raw_id
    ) VALUES (
      v_aligned_ts, v_plant_id, v_point_id, v_device_id,
      lower(metric_kv.key), v_value,
      v_raw_id
    );
  END LOOP;

  UPDATE device
  SET last_seen_at = v_ingest_ts
  WHERE device_id = v_device_id;
END;
$$;
