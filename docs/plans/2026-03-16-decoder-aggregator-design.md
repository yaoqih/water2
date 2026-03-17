# Decoder Aggregator Design

## Context

- Current data-plane contract is fixed to `water/v1/{plant_id}/{point_id}/{device_id}/telemetry` with flat JSON payloads.
- New upload modules publish pure hex strings containing `Modbus-RTU` query and response frames.
- Four sensor families must be supported based on vendor PDFs in `docs/new_sersor/`.
- The user only wants 1-minute averages stored in the database and does not want to retain raw second-level values.

## Goals

- Add a decoder layer without changing the internal database ingest contract.
- Keep existing `EMQX -> ingest_telemetry(...) -> TimescaleDB -> Grafana` standard flow intact.
- Support profile-based decoding for turbidity, COD, suspended solids, and ammonia nitrogen sensors.
- Aggregate by minute before writing to the database.

## Non-goals

- No raw hex payload storage in PostgreSQL.
- No change to `ingest_telemetry()` payload semantics.
- No dashboard redesign in this increment.
- No attempt to infer sensor type from Modbus address alone.

## Chosen Design

- Introduce a `decoder-aggregator` sidecar service in Compose.
- New raw topic:
  - `water/raw/v1/{plant_id}/{point_id}/{device_id}/telemetry`
- Existing standard topic remains unchanged:
  - `water/v1/{plant_id}/{point_id}/{device_id}/telemetry`
- The sidecar:
  - subscribes to `water/raw/v1/+/+/+/telemetry`
  - loads a local device profile config file
  - supports `source_device_id -> target_device_id` mapping
  - validates hex payloads and Modbus CRC
  - decodes the response frame according to the configured profile
  - can filter or rename decoded metrics before republish
  - accumulates per-minute averages in memory
  - publishes one flat JSON payload per minute to `water/v1/.../telemetry`

## Why This Design

- It preserves the clean internal contract already assumed by:
  - `scripts/stack.sh`
  - `ingest_telemetry(...)`
  - `metric_sample`
  - Grafana queries
- It keeps protocol-specific logic at the system boundary.
- It avoids pushing Modbus parsing and minute-window state into SQL or EMQX rule logic.
- It fits the repository shape: infrastructure services managed by Compose plus runtime integration in `scripts/stack.sh`.

## Data Contracts

### Raw ingest

- Topic:
  - `water/raw/v1/{plant_id}/{point_id}/{device_id}/telemetry`
- Payload:
  - pure hex string
  - current supported format: `query_frame + response_frame`

### Standard publish

- Topic:
  - `water/v1/{plant_id}/{point_id}/{device_id}/telemetry`
- Payload:
  - flat JSON object
- Metric naming:
  - `rs_zd_turbidity` -> `turbidity`, `temperature`
  - `rs_cod` -> `cod`, `temperature`, `turbidity`
  - `rs_ss` -> `ss`, `temperature`
  - `rs_nhn_amnitro` -> `amnitro`, `temperature`

Note:

- The ammonia sensor `0x0001` register is treated as manual pH compensation, not measured `ph`, based on the vendor PDF.

## Device Profile Strategy

- First increment uses a local JSON config file mounted into the sidecar container.
- Each device entry defines:
  - `device_id` as raw source device ID
  - `profile_type`
  - `sensor_range`
  - optional `target_device_id`
  - optional `publish_metrics`
  - optional `metric_aliases`

This avoids immediate schema/UI changes while keeping room for future control-plane integration.

## Aggregation Rules

- Window key:
  - `(device_id, minute_bucket, metric)`
- Window timestamp:
  - UTC minute floor of service receive time
- Aggregation:
  - maintain `sum` and `count`
  - publish `sum / count` once the minute is closed
- Flush delay:
  - default 5 seconds after the minute boundary

## Failure Handling

- Reject and log:
  - malformed hex
  - odd-length payload
  - unsupported topic shape
  - unknown device profile
  - duplicate output metric names within one merged logical device
  - CRC mismatch
  - unsupported function code or byte count for the configured profile
- Do not publish partial or invalid decoded results.
- Service restart may drop the current unflushed minute in this increment.

## Operational Notes

- Existing EMQX direct-ingest rule continues to consume only `water/v1/.../telemetry`.
- Device MQTT ACLs need to allow publishing raw topics.
- Sidecar MQTT ACLs need:
  - subscribe raw topics
  - publish standard topics

## Files Expected To Change

- `docker-compose.yml`
- `env/prod.env.example`
- `env/test.env.example`
- `scripts/stack.sh`
- `docs/ARCHITECTURE.md`
- `docs/MQTT_TIMESCALE_V1_SPEC.md`
- `docs/DATABASE_SCHEMA.md`
- new service directory for `decoder-aggregator`

## Verification Outline

- Unit tests for:
  - CRC validation
  - frame splitting
  - per-profile decoding
  - minute aggregation flush behavior
- Config validation for unknown or inconsistent profiles
- Compose config validation
