# Water API Collector Design

## Context

The public water-quality API provides paginated, pull-based samples while the stack accepts
flat telemetry through MQTT. The source timestamp (`collectTime`) must remain the time-series
timestamp for historical backfill and continuous polling.

## Decision

Add a `water-api-collector` Compose service. It reads configured source mappings, fetches each
source in at-most-30-day windows, publishes the mapped data to the existing standard MQTT topic,
and persists its per-source high-water mark in a Docker volume. Each poll begins before that
watermark by a configured overlap period.

The collector publishes a reserved `_observed_at` RFC 3339 field alongside numeric metrics. The
existing ingestion function removes that field before metric expansion, writes it to
`raw_message.source_ts`, and uses it to align `metric_sample.ingest_ts`. A partial unique index
on `(topic, source_ts)` makes retries and overlap updates idempotent.

## Mapping

| API field | Canonical metric |
| --- | --- |
| `waterTemperature` | `watert` |
| `turbidity` | `turbidity` |
| `suspendedSubstance` | `ss` |
| `cod` | `cod` |
| `ammoniaNitrogen` | `amnitro` |

The first source is configured as plant `plant_cq_jlp_zouma_rehousing`, point
`pt_cq_jlp_zouma_rehousing_inlet`, and device
`dev_cq_jlp_zouma_rehousing_inlet_01`.

## Failure Handling

- Reject malformed API pages, non-success business codes, invalid timestamps, and non-numeric
  metric values with structured logs.
- Retry only on the next poll; do not advance the cursor after a failed page or MQTT publish.
- Persist the cursor atomically after a successful window. Replayed records are safe because the
  database replaces the existing source-time sample.
- `initial_start_time` is explicit because the API cannot report the earliest available time.

## Rollout and Rollback

Apply schema changes with `stack.sh configure`, create plant/point/device metadata, configure the
source and MQTT credentials, then start the service. Rollback is stopping/removing the collector;
the additive database fields and index do not affect existing MQTT producers.
