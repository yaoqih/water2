# Metric Source Binding

## Design

- Problem: the current monitor dashboards treat `point_id + metric` as a single display series, but raw telemetry preserves only `device_id` as the real source. When two devices at the same point upload the same metric, Grafana mixes or arbitrarily picks one row.
- Goal: keep MQTT/topic/payload contracts unchanged, preserve raw detail, and add one explicit place to decide which device should represent each `point_id + metric` in dashboards.
- Minimal solution:
  - Add `point_metric_source(point_id, metric, device_id)` as the explicit display-source binding.
  - Add `admin_api.v_point_metric_effective` for dashboards.
  - In `v_point_metric_effective`, use explicit bindings first; when no explicit binding exists, auto-resolve only when history shows exactly one device for that `point_id + metric`.
  - Add one Grafana admin page to maintain bindings.
- Non-goals:
  - No MQTT protocol change.
  - No metric renaming such as `ph_1/ph_2`.
  - No raw export behavior change.

## Implementation Plan

1. Add the new binding table and constraints in `postgres/initdb/001_iot_init.sql`.
2. Add admin views and CRUD functions in `postgres/initdb/002_admin_api.sql`.
3. Add a new Admin dashboard spec and navigation entry for source bindings.
4. Regenerate admin dashboards.
5. Update plant monitor dashboards to query `admin_api.v_point_metric_effective` instead of raw `metric_sample`.
6. Run focused DB and dashboard verification in the test stack.

## Verification

- Red: `SELECT 1 FROM admin_api.v_point_metric_effective LIMIT 1;` fails before schema change in `test`.
- Green:
  - replay `001_iot_init.sql` and `002_admin_api.sql` into `test`
  - verify `admin_api.v_point_metric_effective` exists
  - insert an explicit binding and confirm the view returns the bound device only
  - run `./scripts/generate_admin_dashboards.sh --check`
