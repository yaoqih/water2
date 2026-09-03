# Water API Collector Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ingest historical and continuously polled public water-quality data through the existing MQTT path without duplicate samples.

**Architecture:** A Python collector reads source mappings, paginates HTTP results in bounded time windows, maps fields to canonical metrics, and publishes standard MQTT telemetry. A reserved timestamp field is consumed by PostgreSQL so the sample retains source time and overlap retries update rather than duplicate data.

**Tech Stack:** Python 3.12, urllib, paho-mqtt, PostgreSQL/TimescaleDB, Docker Compose, unittest.

---

### Task 1: Add a source-time ingestion contract

**Files:**
- Modify: `postgres/initdb/001_iot_init.sql`
- Test: `postgres/tests/test_ingest_observed_time.sql`

1. Add a failing SQL regression test for `_observed_at` alignment and duplicate replacement.
2. Run it against the test database and confirm the current function rejects the string field.
3. Add `raw_message.source_ts`, a partial unique index, and `_observed_at` parsing/removal in `ingest_telemetry`.
4. Re-run the SQL regression test.

### Task 2: Add collector domain tests and implementation

**Files:**
- Create: `services/water_api_collector/tests/test_collector.py`
- Create: `services/water_api_collector/water_api_collector/*.py`
- Create: `services/water_api_collector/config/sources.example.json`

1. Write failing unit tests for mapping, API pagination, time-window selection, atomic cursor persistence, and no cursor advance on publish failure.
2. Run the tests and confirm missing-module failures.
3. Implement the minimal testable collector modules.
4. Re-run the unit tests.

### Task 3: Wire deployment and operational configuration

**Files:**
- Modify: `docker-compose.yml`
- Create: `services/water_api_collector/Dockerfile`
- Create: `services/water_api_collector/requirements.txt`
- Create: `services/water_api_collector/config/sources.json`
- Modify: `env/*.example`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/MQTT_TIMESCALE_V1_SPEC.md`

1. Add a failing Compose configuration check for the new service's required configuration.
2. Add the collector service, persistent state volume, health-compatible runtime settings, and example source mapping.
3. Document the `_observed_at` reserved field and HTTP collector path.
4. Run Compose config and the full test suite.

### Task 4: Validate against the public endpoint

**Files:** None

1. Query the documented endpoint with a bounded date range.
2. Record HTTP and business response status plus whether field-level data was available.
3. Build the service image and run static/unit verification.
