CREATE SCHEMA IF NOT EXISTS admin_api;

CREATE TABLE IF NOT EXISTS admin_api.audit_log (
  audit_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor          TEXT NOT NULL,
  action         TEXT NOT NULL,
  object_type    TEXT NOT NULL,
  object_id      TEXT NOT NULL,
  before_data    JSONB,
  after_data     JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION admin_api.current_actor()
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.sub', true), ''),
    NULLIF(current_setting('request.jwt.claim.role', true), ''),
    current_user::text
  );
$$;

CREATE OR REPLACE FUNCTION admin_api.enforce_postgrest_token()
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_expected TEXT;
  v_given TEXT;
BEGIN
  v_expected := NULLIF(current_setting('app.settings.admin_token', true), '');
  IF v_expected IS NULL THEN
    RETURN;
  END IF;

  v_given := NULLIF((current_setting('request.headers', true)::jsonb ->> 'x-admin-token'), '');
  IF v_given IS DISTINCT FROM v_expected THEN
    RAISE insufficient_privilege USING MESSAGE = 'invalid x-admin-token';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION admin_api.write_audit(
  p_action TEXT,
  p_object_type TEXT,
  p_object_id TEXT,
  p_before JSONB,
  p_after JSONB
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = admin_api, public
AS $$
BEGIN
  INSERT INTO admin_api.audit_log(actor, action, object_type, object_id, before_data, after_data)
  VALUES (admin_api.current_actor(), p_action, p_object_type, p_object_id, p_before, p_after);
END;
$$;

CREATE OR REPLACE VIEW admin_api.v_control_home AS
SELECT
  (SELECT count(*) FROM plant) AS plant_count,
  (SELECT count(*) FROM point) AS point_count,
  (SELECT count(*) FROM device) AS device_count,
  (SELECT count(*) FROM device WHERE enabled) AS enabled_device_count,
  (SELECT count(*) FROM device WHERE enabled = false) AS disabled_device_count,
  (SELECT count(*) FROM device WHERE enabled AND last_seen_at >= now() - interval '5 minutes') AS online_device_count,
  (SELECT count(*) FROM admin_api.audit_log WHERE created_at >= now() - interval '24 hours') AS audit_24h_count;

CREATE OR REPLACE VIEW admin_api.v_plant_list AS
SELECT
  p.plant_id,
  p.plant_name,
  p.longitude,
  p.latitude,
  p.timezone,
  p.created_at,
  count(DISTINCT pt.point_id) AS point_count,
  count(DISTINCT d.device_id) AS device_count
FROM plant p
LEFT JOIN point pt ON pt.plant_id = p.plant_id
LEFT JOIN device d ON d.point_id = pt.point_id
GROUP BY p.plant_id, p.plant_name, p.longitude, p.latitude, p.timezone, p.created_at;

CREATE OR REPLACE VIEW admin_api.v_point_list AS
SELECT
  pt.point_id,
  pt.plant_id,
  p.plant_name,
  pt.point_type,
  pt.point_name,
  pt.created_at,
  count(DISTINCT d.device_id) AS device_count
FROM point pt
JOIN plant p ON p.plant_id = pt.plant_id
LEFT JOIN device d ON d.point_id = pt.point_id
GROUP BY pt.point_id, pt.plant_id, p.plant_name, pt.point_type, pt.point_name, pt.created_at;

CREATE OR REPLACE VIEW admin_api.v_device_list AS
SELECT
  d.device_id,
  d.point_id,
  pt.plant_id,
  p.plant_name,
  pt.point_type,
  pt.point_name,
  d.report_interval_sec,
  d.align_mode,
  d.enabled,
  d.last_seen_at,
  d.created_at
FROM device d
JOIN point pt ON pt.point_id = d.point_id
JOIN plant p ON p.plant_id = pt.plant_id;

CREATE OR REPLACE VIEW admin_api.v_metric_dict AS
SELECT
  metric,
  display_name,
  unit,
  alarm_low,
  alarm_high,
  visible
FROM metric_dict;

DROP VIEW IF EXISTS admin_api.v_metric_export_fields;
DROP VIEW IF EXISTS admin_api.v_metric_export;

CREATE OR REPLACE VIEW admin_api.v_metric_export AS
SELECT
  ms.ingest_ts,
  ms.plant_id,
  p.plant_name,
  p.timezone AS plant_timezone,
  ms.point_id,
  pt.point_name,
  pt.point_type,
  ms.device_id,
  ms.metric,
  md.unit,
  md.alarm_low,
  md.alarm_high,
  ms.value_num,
  rm.topic,
  ms.raw_id
FROM metric_sample ms
LEFT JOIN plant p ON p.plant_id = ms.plant_id
LEFT JOIN point pt ON pt.point_id = ms.point_id AND pt.plant_id = ms.plant_id
LEFT JOIN metric_dict md ON md.metric = ms.metric
LEFT JOIN raw_message rm ON rm.raw_id = ms.raw_id;

CREATE OR REPLACE VIEW admin_api.v_metric_export_fields AS
SELECT
  f.field_order,
  f.field_key,
  f.field_label,
  f.data_type,
  f.supported_ops,
  f.selected_by_default
FROM (
  VALUES
    (1,  'ingest_ts',              '采集时间',       'timestamptz',      'eq,gt,gte,lt,lte,order', true),
    (2,  'plant_id',               '厂站ID',         'text',             'eq,in,ilike',            true),
    (3,  'plant_name',             '厂站名称',       'text',             'eq,in,ilike',            true),
    (4,  'plant_timezone',         '厂站时区',       'text',             'eq,in',                  false),
    (5,  'point_id',               '点位ID',         'text',             'eq,in,ilike',            true),
    (6,  'point_name',             '点位名称',       'text',             'eq,in,ilike',            true),
    (7,  'point_type',             '点位类型',       'text',             'eq,in',                  true),
    (8,  'device_id',              '设备ID',         'text',             'eq,in,ilike',            true),
    (9,  'metric',                 '指标编码',       'text',             'eq,in,ilike',            true),
    (10, 'unit',                   '单位',           'text',             'eq,in,ilike',            true),
    (11, 'alarm_low',              '告警下限',       'double precision', 'eq,gt,gte,lt,lte,is',    false),
    (12, 'alarm_high',             '告警上限',       'double precision', 'eq,gt,gte,lt,lte,is',    false),
    (13, 'value_num',              '指标值',         'double precision', 'eq,gt,gte,lt,lte',       true),
    (14, 'topic',                  '主题',           'text',             'eq,in,ilike',            false),
    (15, 'raw_id',                 '原始消息ID',     'bigint',           'eq,gt,gte,lt,lte',       false)
) AS f(field_order, field_key, field_label, data_type, supported_ops, selected_by_default);

DROP FUNCTION IF EXISTS admin_api.export_metric_rows(TEXT[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT);
CREATE OR REPLACE FUNCTION admin_api.export_metric_rows(
  p_fields TEXT[] DEFAULT NULL,
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_plant_id TEXT DEFAULT NULL,
  p_point_id TEXT DEFAULT NULL,
  p_device_id TEXT DEFAULT NULL,
  p_metric TEXT DEFAULT NULL,
  p_point_type TEXT DEFAULT NULL,
  p_topic TEXT DEFAULT NULL,
  p_limit INT DEFAULT 1000
) RETURNS TABLE(
  row_data JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, admin_api
AS $$
DECLARE
  v_allowed_fields CONSTANT TEXT[] := ARRAY[
    'ingest_ts',
    'plant_id',
    'plant_name',
    'plant_timezone',
    'point_id',
    'point_name',
    'point_type',
    'device_id',
    'metric',
    'unit',
    'alarm_low',
    'alarm_high',
    'value_num',
    'topic',
    'raw_id'
  ];
  v_default_fields CONSTANT TEXT[] := ARRAY[
    'ingest_ts',
    'plant_id',
    'plant_name',
    'point_id',
    'point_type',
    'device_id',
    'metric',
    'value_num',
    'unit'
  ];
  v_fields TEXT[];
  v_invalid_fields TEXT[];
  v_drop_fields TEXT[];
  v_limit INT;
  v_plant_id TEXT;
  v_point_id TEXT;
  v_device_id TEXT;
  v_metric TEXT;
  v_point_type TEXT;
  v_topic TEXT;
BEGIN
  SELECT array_agg(DISTINCT norm.f ORDER BY norm.f)
  INTO v_fields
  FROM (
    SELECT lower(trim(raw.f)) AS f
    FROM unnest(COALESCE(p_fields, ARRAY[]::TEXT[])) AS raw(f)
  ) AS norm
  WHERE norm.f <> '';

  IF v_fields IS NULL OR cardinality(v_fields) = 0 THEN
    v_fields := v_default_fields;
  END IF;

  SELECT array_agg(f ORDER BY f)
  INTO v_invalid_fields
  FROM unnest(v_fields) AS t(f)
  WHERE NOT (f = ANY(v_allowed_fields));

  IF v_invalid_fields IS NOT NULL THEN
    RAISE EXCEPTION 'unsupported export field(s): %', array_to_string(v_invalid_fields, ',');
  END IF;

  IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_to <= p_from THEN
    RAISE EXCEPTION 'invalid time range: p_to must be greater than p_from';
  END IF;

  v_plant_id := NULLIF(trim(COALESCE(p_plant_id, '')), '');
  v_point_id := NULLIF(trim(COALESCE(p_point_id, '')), '');
  v_device_id := NULLIF(trim(COALESCE(p_device_id, '')), '');
  v_metric := NULLIF(lower(trim(COALESCE(p_metric, ''))), '');
  v_point_type := NULLIF(lower(trim(COALESCE(p_point_type, ''))), '');
  v_topic := NULLIF(trim(COALESCE(p_topic, '')), '');

  IF v_point_type IS NOT NULL AND v_point_type NOT IN ('all', 'inlet', 'outlet') THEN
    RAISE EXCEPTION 'invalid point_type: %', v_point_type;
  END IF;

  v_limit := COALESCE(p_limit, 1000);
  IF v_limit <= 0 THEN
    v_limit := 50000;
  END IF;
  v_limit := LEAST(v_limit, 50000);

  SELECT array_agg(f)
  INTO v_drop_fields
  FROM unnest(v_allowed_fields) AS t(f)
  WHERE NOT (f = ANY(v_fields));

  RETURN QUERY
  SELECT to_jsonb(ve) - COALESCE(v_drop_fields, ARRAY[]::TEXT[])
  FROM admin_api.v_metric_export ve
  WHERE (p_from IS NULL OR ve.ingest_ts >= p_from)
    AND (p_to IS NULL OR ve.ingest_ts < p_to)
    AND (v_plant_id IS NULL OR ve.plant_id = v_plant_id)
    AND (v_point_id IS NULL OR ve.point_id = v_point_id)
    AND (v_device_id IS NULL OR ve.device_id = v_device_id)
    AND (v_metric IS NULL OR ve.metric = v_metric)
    AND (v_point_type IS NULL OR v_point_type = 'all' OR ve.point_type = v_point_type)
    AND (v_topic IS NULL OR ve.topic = v_topic)
  ORDER BY ve.ingest_ts DESC
  LIMIT v_limit;
END;
$$;

CREATE OR REPLACE VIEW admin_api.v_device_conn_profile AS
SELECT
  d.device_id,
  pt.plant_id,
  d.point_id,
  format('water/v1/%s/%s/%s/telemetry', pt.plant_id, d.point_id, d.device_id) AS telemetry_topic,
  format('water/v1/%s/%s/%s/cmd/+', pt.plant_id, d.point_id, d.device_id) AS cmd_topic_pattern,
  d.device_id AS expected_client_id,
  d.report_interval_sec,
  d.align_mode,
  d.enabled,
  d.last_seen_at,
  d.created_at
FROM device d
JOIN point pt ON pt.point_id = d.point_id;

CREATE OR REPLACE VIEW admin_api.v_audit_log AS
SELECT
  audit_id,
  actor,
  action,
  object_type,
  object_id,
  before_data,
  after_data,
  created_at
FROM admin_api.audit_log;

CREATE OR REPLACE FUNCTION admin_api.upsert_plant(
  p_plant_id TEXT,
  p_plant_name TEXT,
  p_longitude NUMERIC DEFAULT NULL,
  p_latitude NUMERIC DEFAULT NULL,
  p_timezone TEXT DEFAULT 'Asia/Shanghai'
) RETURNS TABLE(
  plant_id TEXT,
  plant_name TEXT,
  longitude NUMERIC,
  latitude NUMERIC,
  timezone TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, admin_api
AS $$
DECLARE
  v_before JSONB;
  v_after JSONB;
BEGIN
  p_plant_id := NULLIF(trim(p_plant_id), '');
  p_plant_name := NULLIF(trim(p_plant_name), '');
  p_timezone := COALESCE(NULLIF(trim(p_timezone), ''), 'Asia/Shanghai');

  IF p_plant_id IS NULL THEN
    RAISE EXCEPTION 'plant_id is required';
  END IF;
  IF p_plant_name IS NULL THEN
    RAISE EXCEPTION 'plant_name is required';
  END IF;

  SELECT to_jsonb(p) INTO v_before
  FROM plant p
  WHERE p.plant_id = p_plant_id;

  INSERT INTO plant(plant_id, plant_name, longitude, latitude, timezone)
  VALUES (p_plant_id, p_plant_name, p_longitude, p_latitude, p_timezone)
  ON CONFLICT ON CONSTRAINT plant_pkey DO UPDATE
    SET plant_name = EXCLUDED.plant_name,
        longitude = EXCLUDED.longitude,
        latitude = EXCLUDED.latitude,
        timezone = EXCLUDED.timezone;

  SELECT to_jsonb(p) INTO v_after
  FROM plant p
  WHERE p.plant_id = p_plant_id;

  PERFORM admin_api.write_audit('upsert', 'plant', p_plant_id, v_before, v_after);

  RETURN QUERY
  SELECT p.plant_id, p.plant_name, p.longitude, p.latitude, p.timezone, p.created_at
  FROM plant p
  WHERE p.plant_id = p_plant_id;
END;
$$;

CREATE OR REPLACE FUNCTION admin_api.upsert_point(
  p_point_id TEXT,
  p_plant_id TEXT,
  p_point_type TEXT,
  p_point_name TEXT DEFAULT NULL
) RETURNS TABLE(
  point_id TEXT,
  plant_id TEXT,
  point_type TEXT,
  point_name TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, admin_api
AS $$
DECLARE
  v_before JSONB;
  v_after JSONB;
BEGIN
  p_point_id := NULLIF(trim(p_point_id), '');
  p_plant_id := NULLIF(trim(p_plant_id), '');
  p_point_type := lower(NULLIF(trim(p_point_type), ''));
  p_point_name := NULLIF(trim(COALESCE(p_point_name, '')), '');

  IF p_point_id IS NULL THEN
    RAISE EXCEPTION 'point_id is required';
  END IF;
  IF p_plant_id IS NULL THEN
    RAISE EXCEPTION 'plant_id is required';
  END IF;
  IF p_point_type NOT IN ('inlet', 'outlet') THEN
    RAISE EXCEPTION 'point_type must be inlet or outlet';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM plant p WHERE p.plant_id = p_plant_id) THEN
    RAISE EXCEPTION 'plant not found: %', p_plant_id;
  END IF;

  SELECT to_jsonb(pt) INTO v_before
  FROM point pt
  WHERE pt.point_id = p_point_id;

  INSERT INTO point(point_id, plant_id, point_type, point_name)
  VALUES (p_point_id, p_plant_id, p_point_type, p_point_name)
  ON CONFLICT ON CONSTRAINT point_pkey DO UPDATE
    SET plant_id = EXCLUDED.plant_id,
        point_type = EXCLUDED.point_type,
        point_name = EXCLUDED.point_name;

  SELECT to_jsonb(pt) INTO v_after
  FROM point pt
  WHERE pt.point_id = p_point_id;

  PERFORM admin_api.write_audit('upsert', 'point', p_point_id, v_before, v_after);

  RETURN QUERY
  SELECT pt.point_id, pt.plant_id, pt.point_type, pt.point_name, pt.created_at
  FROM point pt
  WHERE pt.point_id = p_point_id;
END;
$$;

CREATE OR REPLACE FUNCTION admin_api.upsert_device(
  p_device_id TEXT,
  p_point_id TEXT,
  p_report_interval_sec INT DEFAULT 60,
  p_align_mode TEXT DEFAULT 'floor',
  p_enabled BOOLEAN DEFAULT true
) RETURNS TABLE(
  device_id TEXT,
  point_id TEXT,
  plant_id TEXT,
  report_interval_sec INT,
  align_mode TEXT,
  enabled BOOLEAN,
  last_seen_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, admin_api
AS $$
DECLARE
  v_before JSONB;
  v_after JSONB;
BEGIN
  p_device_id := NULLIF(trim(p_device_id), '');
  p_point_id := NULLIF(trim(p_point_id), '');
  p_align_mode := lower(COALESCE(NULLIF(trim(p_align_mode), ''), 'floor'));
  p_report_interval_sec := COALESCE(p_report_interval_sec, 60);
  p_enabled := COALESCE(p_enabled, true);

  IF p_device_id IS NULL THEN
    RAISE EXCEPTION 'device_id is required';
  END IF;
  IF p_point_id IS NULL THEN
    RAISE EXCEPTION 'point_id is required';
  END IF;
  IF p_report_interval_sec < 1 OR p_report_interval_sec > 3600 THEN
    RAISE EXCEPTION 'report_interval_sec must be between 1 and 3600';
  END IF;
  IF p_align_mode NOT IN ('floor', 'round') THEN
    RAISE EXCEPTION 'align_mode must be floor or round';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM point pt WHERE pt.point_id = p_point_id) THEN
    RAISE EXCEPTION 'point not found: %', p_point_id;
  END IF;

  SELECT to_jsonb(d) INTO v_before
  FROM device d
  WHERE d.device_id = p_device_id;

  INSERT INTO device(device_id, point_id, report_interval_sec, align_mode, enabled)
  VALUES (p_device_id, p_point_id, p_report_interval_sec, p_align_mode, p_enabled)
  ON CONFLICT ON CONSTRAINT device_pkey DO UPDATE
    SET point_id = EXCLUDED.point_id,
        report_interval_sec = EXCLUDED.report_interval_sec,
        align_mode = EXCLUDED.align_mode,
        enabled = EXCLUDED.enabled;

  SELECT to_jsonb(d) INTO v_after
  FROM device d
  WHERE d.device_id = p_device_id;

  PERFORM admin_api.write_audit('upsert', 'device', p_device_id, v_before, v_after);

  RETURN QUERY
  SELECT d.device_id,
         d.point_id,
         pt.plant_id,
         d.report_interval_sec,
         d.align_mode,
         d.enabled,
         d.last_seen_at,
         d.created_at
  FROM device d
  JOIN point pt ON pt.point_id = d.point_id
  WHERE d.device_id = p_device_id;
END;
$$;

CREATE OR REPLACE FUNCTION admin_api.toggle_device(
  p_device_id TEXT,
  p_enabled BOOLEAN
) RETURNS TABLE(
  device_id TEXT,
  enabled BOOLEAN,
  last_seen_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, admin_api
AS $$
DECLARE
  v_before JSONB;
  v_after JSONB;
BEGIN
  p_device_id := NULLIF(trim(p_device_id), '');

  IF p_device_id IS NULL THEN
    RAISE EXCEPTION 'device_id is required';
  END IF;
  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'enabled is required';
  END IF;

  SELECT to_jsonb(d) INTO v_before
  FROM device d
  WHERE d.device_id = p_device_id;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'device not found: %', p_device_id;
  END IF;

  UPDATE device d
  SET enabled = p_enabled
  WHERE d.device_id = p_device_id;

  SELECT to_jsonb(d) INTO v_after
  FROM device d
  WHERE d.device_id = p_device_id;

  PERFORM admin_api.write_audit('toggle', 'device', p_device_id, v_before, v_after);

  RETURN QUERY
  SELECT d.device_id, d.enabled, d.last_seen_at
  FROM device d
  WHERE d.device_id = p_device_id;
END;
$$;

DROP FUNCTION IF EXISTS admin_api.upsert_metric(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS admin_api.upsert_metric(TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION);
DROP FUNCTION IF EXISTS admin_api.upsert_metric(TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN);

CREATE OR REPLACE FUNCTION admin_api.upsert_metric(
  p_metric TEXT,
  p_display_name TEXT,
  p_unit TEXT DEFAULT NULL,
  p_alarm_low DOUBLE PRECISION DEFAULT NULL,
  p_alarm_high DOUBLE PRECISION DEFAULT NULL,
  p_visible BOOLEAN DEFAULT true
) RETURNS TABLE(
  metric TEXT,
  display_name TEXT,
  unit TEXT,
  visible BOOLEAN,
  alarm_low DOUBLE PRECISION,
  alarm_high DOUBLE PRECISION
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, admin_api
AS $$
DECLARE
  v_before JSONB;
  v_after JSONB;
BEGIN
  p_metric := lower(NULLIF(trim(p_metric), ''));
  p_display_name := NULLIF(trim(p_display_name), '');
  p_unit := NULLIF(trim(COALESCE(p_unit, '')), '');
  p_visible := COALESCE(p_visible, true);

  IF p_metric IS NULL THEN
    RAISE EXCEPTION 'metric is required';
  END IF;
  IF p_display_name IS NULL THEN
    RAISE EXCEPTION 'display_name is required';
  END IF;
  IF p_alarm_low IS NOT NULL AND p_alarm_high IS NOT NULL AND p_alarm_low > p_alarm_high THEN
    RAISE EXCEPTION 'alarm_low must be <= alarm_high';
  END IF;

  SELECT to_jsonb(m) INTO v_before
  FROM metric_dict m
  WHERE m.metric = p_metric;

  INSERT INTO metric_dict(metric, display_name, unit, visible, alarm_low, alarm_high)
  VALUES (p_metric, p_display_name, p_unit, p_visible, p_alarm_low, p_alarm_high)
  ON CONFLICT ON CONSTRAINT metric_dict_pkey DO UPDATE
    SET display_name = EXCLUDED.display_name,
        unit = EXCLUDED.unit,
        visible = EXCLUDED.visible,
        alarm_low = EXCLUDED.alarm_low,
        alarm_high = EXCLUDED.alarm_high;

  SELECT to_jsonb(m) INTO v_after
  FROM metric_dict m
  WHERE m.metric = p_metric;

  PERFORM admin_api.write_audit('upsert', 'metric', p_metric, v_before, v_after);

  RETURN QUERY
  SELECT m.metric, m.display_name, m.unit, m.visible, m.alarm_low, m.alarm_high
  FROM metric_dict m
  WHERE m.metric = p_metric;
END;
$$;


CREATE OR REPLACE FUNCTION admin_api.delete_device(
  p_device_id TEXT
) RETURNS TABLE(
  device_id TEXT,
  deleted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, admin_api
AS $$
DECLARE
  v_before JSONB;
BEGIN
  p_device_id := NULLIF(trim(p_device_id), '');

  IF p_device_id IS NULL THEN
    RAISE EXCEPTION 'device_id is required';
  END IF;

  SELECT to_jsonb(d) INTO v_before
  FROM device d
  WHERE d.device_id = p_device_id;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'device not found: %', p_device_id;
  END IF;

  DELETE FROM device d
  WHERE d.device_id = p_device_id;

  PERFORM admin_api.write_audit('delete', 'device', p_device_id, v_before, NULL);

  RETURN QUERY
  SELECT p_device_id, true;
END;
$$;

CREATE OR REPLACE FUNCTION admin_api.delete_point(
  p_point_id TEXT,
  p_force BOOLEAN DEFAULT false
) RETURNS TABLE(
  point_id TEXT,
  deleted BOOLEAN,
  deleted_device_count INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, admin_api
AS $$
DECLARE
  v_before JSONB;
  v_has_point BOOLEAN;
  v_deleted_device_count INT := 0;
BEGIN
  p_point_id := NULLIF(trim(p_point_id), '');
  p_force := COALESCE(p_force, false);

  IF p_point_id IS NULL THEN
    RAISE EXCEPTION 'point_id is required';
  END IF;

  SELECT EXISTS(SELECT 1 FROM point pt WHERE pt.point_id = p_point_id)
  INTO v_has_point;

  IF NOT v_has_point THEN
    RAISE EXCEPTION 'point not found: %', p_point_id;
  END IF;

  SELECT jsonb_build_object(
    'point', to_jsonb(pt),
    'devices', COALESCE((SELECT jsonb_agg(to_jsonb(d)) FROM device d WHERE d.point_id = p_point_id), '[]'::jsonb)
  )
  INTO v_before
  FROM point pt
  WHERE pt.point_id = p_point_id;

  SELECT count(*)::INT INTO v_deleted_device_count
  FROM device d
  WHERE d.point_id = p_point_id;

  IF v_deleted_device_count > 0 AND NOT p_force THEN
    RAISE EXCEPTION 'point has % devices, set p_force=true to delete', v_deleted_device_count;
  END IF;

  IF p_force THEN
    DELETE FROM device d
    WHERE d.point_id = p_point_id;
  ELSE
    v_deleted_device_count := 0;
  END IF;

  DELETE FROM point pt
  WHERE pt.point_id = p_point_id;

  PERFORM admin_api.write_audit('delete', 'point', p_point_id, v_before, NULL);

  RETURN QUERY
  SELECT p_point_id, true, v_deleted_device_count;
END;
$$;

CREATE OR REPLACE FUNCTION admin_api.delete_plant(
  p_plant_id TEXT,
  p_force BOOLEAN DEFAULT false
) RETURNS TABLE(
  plant_id TEXT,
  deleted BOOLEAN,
  deleted_point_count INT,
  deleted_device_count INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, admin_api
AS $$
DECLARE
  v_before JSONB;
  v_has_plant BOOLEAN;
  v_deleted_point_count INT := 0;
  v_deleted_device_count INT := 0;
BEGIN
  p_plant_id := NULLIF(trim(p_plant_id), '');
  p_force := COALESCE(p_force, false);

  IF p_plant_id IS NULL THEN
    RAISE EXCEPTION 'plant_id is required';
  END IF;

  SELECT EXISTS(SELECT 1 FROM plant p WHERE p.plant_id = p_plant_id)
  INTO v_has_plant;

  IF NOT v_has_plant THEN
    RAISE EXCEPTION 'plant not found: %', p_plant_id;
  END IF;

  SELECT jsonb_build_object(
    'plant', to_jsonb(p),
    'points', COALESCE((SELECT jsonb_agg(to_jsonb(pt)) FROM point pt WHERE pt.plant_id = p_plant_id), '[]'::jsonb),
    'devices', COALESCE((
      SELECT jsonb_agg(to_jsonb(d))
      FROM device d
      JOIN point pt ON pt.point_id = d.point_id
      WHERE pt.plant_id = p_plant_id
    ), '[]'::jsonb)
  )
  INTO v_before
  FROM plant p
  WHERE p.plant_id = p_plant_id;

  SELECT count(*)::INT INTO v_deleted_point_count
  FROM point pt
  WHERE pt.plant_id = p_plant_id;

  SELECT count(*)::INT INTO v_deleted_device_count
  FROM device d
  JOIN point pt ON pt.point_id = d.point_id
  WHERE pt.plant_id = p_plant_id;

  IF v_deleted_device_count > 0 AND NOT p_force THEN
    RAISE EXCEPTION 'plant has % devices, set p_force=true to delete', v_deleted_device_count;
  END IF;

  IF p_force THEN
    DELETE FROM device d
    USING point pt
    WHERE d.point_id = pt.point_id
      AND pt.plant_id = p_plant_id;
  ELSE
    v_deleted_device_count := 0;
  END IF;

  DELETE FROM plant p
  WHERE p.plant_id = p_plant_id;

  PERFORM admin_api.write_audit('delete', 'plant', p_plant_id, v_before, NULL);

  RETURN QUERY
  SELECT p_plant_id, true, v_deleted_point_count, v_deleted_device_count;
END;
$$;

CREATE OR REPLACE FUNCTION admin_api.delete_metric(
  p_metric TEXT
) RETURNS TABLE(
  metric TEXT,
  deleted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, admin_api
AS $$
DECLARE
  v_before JSONB;
BEGIN
  p_metric := lower(NULLIF(trim(p_metric), ''));

  IF p_metric IS NULL THEN
    RAISE EXCEPTION 'metric is required';
  END IF;

  SELECT to_jsonb(m) INTO v_before
  FROM metric_dict m
  WHERE m.metric = p_metric;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'metric not found: %', p_metric;
  END IF;

  DELETE FROM metric_dict m
  WHERE m.metric = p_metric;

  PERFORM admin_api.write_audit('delete', 'metric', p_metric, v_before, NULL);

  RETURN QUERY
  SELECT p_metric, true;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'iot_api_viewer') THEN
    CREATE ROLE iot_api_viewer NOLOGIN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'iot_api_editor') THEN
    CREATE ROLE iot_api_editor NOLOGIN;
  END IF;
END;
$$;

GRANT iot_api_viewer TO iot_api_editor;

REVOKE ALL ON SCHEMA admin_api FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA admin_api FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA admin_api FROM PUBLIC;

GRANT USAGE ON SCHEMA admin_api TO iot_api_viewer, iot_api_editor;

GRANT SELECT ON
  admin_api.v_control_home,
  admin_api.v_plant_list,
  admin_api.v_point_list,
  admin_api.v_device_list,
  admin_api.v_metric_dict,
  admin_api.v_metric_export,
  admin_api.v_metric_export_fields,
  admin_api.v_device_conn_profile,
  admin_api.v_audit_log
TO iot_api_viewer, iot_api_editor;

GRANT EXECUTE ON FUNCTION
  admin_api.enforce_postgrest_token(),
  admin_api.upsert_plant(TEXT, TEXT, NUMERIC, NUMERIC, TEXT),
  admin_api.upsert_point(TEXT, TEXT, TEXT, TEXT),
  admin_api.upsert_device(TEXT, TEXT, INT, TEXT, BOOLEAN),
  admin_api.toggle_device(TEXT, BOOLEAN),
  admin_api.upsert_metric(TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN),
  admin_api.export_metric_rows(TEXT[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT),
  admin_api.delete_device(TEXT),
  admin_api.delete_point(TEXT, BOOLEAN),
  admin_api.delete_plant(TEXT, BOOLEAN),
  admin_api.delete_metric(TEXT)
TO iot_api_editor;
