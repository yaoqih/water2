INSERT INTO plant(plant_id, plant_name, timezone)
VALUES (
  'plant_cq_jlp_zouma_rehousing',
  '九龙坡区走马安置房水厂',
  'Asia/Shanghai'
)
ON CONFLICT (plant_id) DO UPDATE
SET plant_name = EXCLUDED.plant_name,
    timezone = EXCLUDED.timezone;

INSERT INTO point(point_id, plant_id, point_type, point_name)
VALUES (
  'pt_cq_jlp_zouma_rehousing_inlet',
  'plant_cq_jlp_zouma_rehousing',
  'inlet',
  '入水口'
)
ON CONFLICT (point_id) DO UPDATE
SET plant_id = EXCLUDED.plant_id,
    point_type = EXCLUDED.point_type,
    point_name = EXCLUDED.point_name;

INSERT INTO device(device_id, point_id, report_interval_sec, align_mode, enabled)
VALUES (
  'dev_cq_jlp_zouma_rehousing_inlet_01',
  'pt_cq_jlp_zouma_rehousing_inlet',
  60,
  'floor',
  true
)
ON CONFLICT (device_id) DO UPDATE
SET point_id = EXCLUDED.point_id,
    report_interval_sec = EXCLUDED.report_interval_sec,
    align_mode = EXCLUDED.align_mode,
    enabled = EXCLUDED.enabled;

INSERT INTO point_metric_source(point_id, metric, device_id)
VALUES
  ('pt_cq_jlp_zouma_rehousing_inlet', 'watert', 'dev_cq_jlp_zouma_rehousing_inlet_01'),
  ('pt_cq_jlp_zouma_rehousing_inlet', 'turbidity', 'dev_cq_jlp_zouma_rehousing_inlet_01'),
  ('pt_cq_jlp_zouma_rehousing_inlet', 'ss', 'dev_cq_jlp_zouma_rehousing_inlet_01'),
  ('pt_cq_jlp_zouma_rehousing_inlet', 'cod', 'dev_cq_jlp_zouma_rehousing_inlet_01'),
  ('pt_cq_jlp_zouma_rehousing_inlet', 'amnitro', 'dev_cq_jlp_zouma_rehousing_inlet_01')
ON CONFLICT (point_id, metric) DO UPDATE
SET device_id = EXCLUDED.device_id;
