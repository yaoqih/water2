# Device Sensor Monitor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a generic Grafana viewer dashboard that shows one selected device's latest metric values and one small line chart per metric with low coupling to plant-specific inlet/outlet logic.

**Architecture:** Add two device-level read views under `admin_api` so Grafana queries stable contracts instead of raw `metric_sample` joins. Build a new viewer dashboard on top of those views with `plant -> point -> device` variables, repeated stat cards and repeated time-series panels, then wire it into viewer navigation, generation, sync, and ACL paths.

**Tech Stack:** PostgreSQL/TimescaleDB views, Grafana dashboard JSON/Jsonnet source, bash deployment scripts, jq/jsonnet validation.

---

## Background

- Current `iot-v1-plant-monitor` is coupled to `inlet/outlet` semantics and `point_id + metric` effective source resolution.
- New requirement is a generic device page:
  - Select `plant`, `point`, `device`
  - Show every metric for that device
  - For each metric show latest value and a small line chart at the same time
- Keep changes additive. Do not break existing plant monitor or upload/decoder flows.

## Acceptance Criteria

1. `admin_api` exposes one latest-row-per-device-metric view and one device-metric time-series view.
2. Grafana RO/Admin roles can read the new views.
3. A new viewer dashboard `iot-v1-device-sensor-monitor` exists and is provisioned by existing scripts.
4. Viewer navigation includes the new page.
5. Grafana sync and ACL scripts treat the new page as a viewer dashboard.
6. Documentation mentions the new page and the new read views.
7. Validation evidence includes dashboard generation checks and SQL/schema replay checks.

## Task 1: Add device monitoring read views

**Files:**
- Modify: `postgres/initdb/002_admin_api.sql`

**Steps:**
1. Add `DROP VIEW IF EXISTS` statements for:
   - `admin_api.v_device_metric_series`
   - `admin_api.v_device_metric_latest`
2. Add `admin_api.v_device_metric_series` after `admin_api.v_point_metric_effective` using direct `metric_sample -> plant -> point -> device -> metric_dict -> raw_message` joins.
3. Include these columns in `v_device_metric_series`:
   - `plant_id`, `plant_name`, `plant_timezone`
   - `point_id`, `point_name`, `point_type`
   - `device_id`, `report_interval_sec`, `align_mode`, `enabled`, `last_seen_at`
   - `metric`, `display_name`, `unit`, `alarm_low`, `alarm_high`, `visible`
   - `ingest_ts`, `value_num`, `topic`, `raw_id`
4. Add `admin_api.v_device_metric_latest` from `v_device_metric_series` using `row_number()` partitioned by `plant_id, point_id, device_id, metric`.
5. Add freshness fields to `v_device_metric_latest`:
   - `freshness_sec`
   - `freshness_budget_sec`
   - `is_fresh`
6. Treat `report_interval_sec` missing or non-positive as a default freshness budget of `300` seconds.

**Verification:**
- Replay `postgres/initdb/002_admin_api.sql` into the test stack.
- Run:
  - `SELECT 1 FROM admin_api.v_device_metric_series LIMIT 1;`
  - `SELECT 1 FROM admin_api.v_device_metric_latest LIMIT 1;`

## Task 2: Expose new views to Grafana roles

**Files:**
- Modify: `scripts/stack.sh`

**Steps:**
1. Extend Grafana DB grants so both RO/Admin Grafana roles can `SELECT`:
   - `admin_api.v_device_metric_series`
   - `admin_api.v_device_metric_latest`
2. Keep changes limited to the existing `configure_grafana_db_roles()` grant list.

**Verification:**
- Re-run `./scripts/stack.sh configure --env test` or inspect generated SQL grant block.

## Task 3: Add generic viewer dashboard

**Files:**
- Create: `grafana/provisioning/dashboards/v1/iot-v1-device-sensor-monitor.json`
- Create: `grafana/provisioning/dashboards/jsonnet/device-sensor-monitor.main.jsonnet`

**Steps:**
1. Create a new dashboard with UID `iot-v1-device-sensor-monitor`.
2. Use datasource `TimescaleDB-RO`.
3. Add variables:
   - `plant_id`
   - `point_id`
   - `device_id`
   - `metric_cards` from `admin_api.v_device_metric_latest`
4. Add top navigation panel with title `导航`.
5. Add one summary panel for selected plant/point/device metadata.
6. Add repeated stat panels over `metric_cards` showing latest value; keep units in panel titles and summarize freshness at the device overview level.
7. Add repeated timeseries panels over `metric_cards` showing recent line charts from `admin_api.v_device_metric_series`.
8. Filter metrics with `visible IS DISTINCT FROM false` so explicitly hidden metrics stay hidden, but metrics without dictionary rows still render.
9. Keep layout generic and independent of inlet/outlet assumptions.
10. Keep navigation library panel content consistent with existing viewer pages.

**Verification:**
- `jq -e . grafana/provisioning/dashboards/v1/iot-v1-device-sensor-monitor.json`
- Render wrapper and compare output:
  - `jsonnet grafana/provisioning/dashboards/jsonnet/device-sensor-monitor.main.jsonnet | jq -e .`

## Task 4: Wire generation, nav, and ACL

**Files:**
- Modify: `grafana/provisioning/dashboards/jsonnet/nav.libsonnet`
- Modify: `scripts/generate_admin_dashboards.sh`
- Modify: `scripts/stack.sh`

**Steps:**
1. Add a viewer navigation link for `iot-v1-device-sensor-monitor`.
2. Extend `scripts/generate_admin_dashboards.sh`:
   - render/check the new dashboard JSON
   - validate it with `jq`
3. Extend `scripts/stack.sh`:
   - include the new UID in navigation library sync
   - include the new UID in viewer dashboard ACLs
4. Keep the existing plant monitor behavior unchanged.

**Verification:**
- Run `./scripts/generate_admin_dashboards.sh --check`
- If outdated, run `./scripts/generate_admin_dashboards.sh`
- Run `./scripts/generate_admin_dashboards.sh --check` again

## Task 5: Update docs

**Files:**
- Modify: `docs/CONTROL_PLANE_GRAFANA_POSTGREST.md`
- Modify: `docs/DATABASE_SCHEMA.md`

**Steps:**
1. Add the new viewer dashboard to the control-plane dashboard list.
2. Document the new `admin_api` read views and their purpose.
3. Keep documentation focused on the new page and read contracts.

**Verification:**
- Read the updated sections and confirm they match implemented names and behavior.

## Task 6: Final validation

**Steps:**
1. Run dashboard generation validation.
2. Run SQL replay for schema validation in the test stack.
3. If possible, query the new views from the test stack with sample limits.
4. Record any gaps that could not be verified locally.

**Command Set:**
```bash
cd /root/iot-stack
./scripts/generate_admin_dashboards.sh --check || ./scripts/generate_admin_dashboards.sh
./scripts/generate_admin_dashboards.sh --check
set -a; source env/test.env; set +a
./scripts/stack.sh configure --env test
docker compose --project-directory /root/iot-stack --env-file env/test.env -p iot-test exec -T timescaledb \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT * FROM admin_api.v_device_metric_latest LIMIT 5;"
docker compose --project-directory /root/iot-stack --env-file env/test.env -p iot-test exec -T timescaledb \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT * FROM admin_api.v_device_metric_series LIMIT 5;"
```
