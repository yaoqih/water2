\set ON_ERROR_STOP on

DO $$
DECLARE
  v_metric_count integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM plant
    WHERE plant_id = 'plant_cq_jlp_zouma_rehousing'
      AND plant_name = '九龙坡区走马安置房水厂'
      AND timezone = 'Asia/Shanghai'
  ) THEN
    RAISE EXCEPTION 'Zouma plant metadata is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM point
    WHERE point_id = 'pt_cq_jlp_zouma_rehousing_inlet'
      AND plant_id = 'plant_cq_jlp_zouma_rehousing'
      AND point_type = 'inlet'
      AND point_name = '入水口'
  ) THEN
    RAISE EXCEPTION 'Zouma inlet point metadata is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM device
    WHERE device_id = 'dev_cq_jlp_zouma_rehousing_inlet_01'
      AND point_id = 'pt_cq_jlp_zouma_rehousing_inlet'
      AND report_interval_sec = 60
      AND align_mode = 'floor'
      AND enabled
  ) THEN
    RAISE EXCEPTION 'Zouma inlet device metadata is missing';
  END IF;

  SELECT count(*) INTO v_metric_count
  FROM point_metric_source
  WHERE point_id = 'pt_cq_jlp_zouma_rehousing_inlet'
    AND device_id = 'dev_cq_jlp_zouma_rehousing_inlet_01'
    AND metric IN ('watert', 'turbidity', 'ss', 'cod', 'amnitro');
  IF v_metric_count <> 5 THEN
    RAISE EXCEPTION 'Zouma inlet metric bindings are incomplete';
  END IF;
END;
$$;

INSERT INTO plant(plant_id, plant_name, timezone)
VALUES ('plant_test_water_api', 'Water API Test', 'Asia/Shanghai')
ON CONFLICT (plant_id) DO NOTHING;

INSERT INTO point(point_id, plant_id, point_type, point_name)
VALUES ('pt_test_water_api_inlet', 'plant_test_water_api', 'inlet', 'Water API Inlet')
ON CONFLICT (point_id) DO NOTHING;

INSERT INTO device(device_id, point_id, report_interval_sec, align_mode, enabled)
VALUES ('dev_test_water_api_inlet_01', 'pt_test_water_api_inlet', 60, 'floor', true)
ON CONFLICT (device_id) DO UPDATE SET enabled = true;

SELECT ingest_telemetry(
  'water/v1/plant_test_water_api/pt_test_water_api_inlet/dev_test_water_api_inlet_01/telemetry',
  '{"_observed_at":"2026-08-02T03:04:05+08:00","cod":80.3}'::jsonb,
  'dev_test_water_api_inlet_01',
  1
);

DO $$
DECLARE
  v_sample_count integer;
  v_value double precision;
  v_time timestamptz;
BEGIN
  SELECT count(*), max(value_num), max(ingest_ts)
  INTO v_sample_count, v_value, v_time
  FROM metric_sample
  WHERE device_id = 'dev_test_water_api_inlet_01'
    AND metric = 'cod'
    AND ingest_ts = '2026-08-02T03:04:00+08:00'::timestamptz;

  IF v_sample_count <> 1 OR v_value <> 80.3 OR v_time <> '2026-08-02T03:04:00+08:00'::timestamptz THEN
    RAISE EXCEPTION 'source timestamp was not used for metric_sample';
  END IF;
END;
$$;

DO $$
BEGIN
  PERFORM ingest_telemetry(
    'water/v1/plant_test_water_api/pt_test_water_api_inlet/dev_test_water_api_inlet_01/telemetry',
    '{"_observed_at":"2026-08-02T03:04:05","cod":80.3}'::jsonb,
    'dev_test_water_api_inlet_01',
    1
  );
  RAISE EXCEPTION 'timestamp without offset was accepted';
EXCEPTION WHEN others THEN
  IF SQLERRM = 'timestamp without offset was accepted' THEN
    RAISE;
  END IF;
END;
$$;

SELECT ingest_telemetry(
  'water/v1/plant_test_water_api/pt_test_water_api_inlet/dev_test_water_api_inlet_01/telemetry',
  '{"_observed_at":"2026-08-02T03:04:05+08:00","cod":81.4}'::jsonb,
  'dev_test_water_api_inlet_01',
  1
);

DO $$
DECLARE
  v_sample_count integer;
  v_value double precision;
BEGIN
  SELECT count(*), max(value_num)
  INTO v_sample_count, v_value
  FROM metric_sample
  WHERE device_id = 'dev_test_water_api_inlet_01'
    AND metric = 'cod'
    AND ingest_ts = '2026-08-02T03:04:00+08:00'::timestamptz;

  IF v_sample_count <> 1 OR v_value <> 81.4 THEN
    RAISE EXCEPTION 'duplicate source sample was not replaced';
  END IF;
END;
$$;
