# Decoder Aggregator Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a profile-driven decoder sidecar that consumes raw Modbus hex payloads, aggregates 1-minute averages, and republishes standard flat JSON telemetry without changing the existing DB ingest contract, including support for merging multiple raw source topics into one logical output device.

**Architecture:** A new `decoder-aggregator` container subscribes to `water/raw/v1/.../telemetry`, decodes payloads based on a mounted JSON device profile file, can map `source_device_id -> target_device_id`, filters or renames metrics when needed, stores in-memory minute buckets, and republishes minute-average JSON to `water/v1/.../telemetry`. Existing EMQX direct-ingest and PostgreSQL data model remain the standard ingest path.

**Tech Stack:** Docker Compose, Bash runtime configuration, Python 3.13, `paho-mqtt`, built-in `unittest`

---

### Task 1: Document The Approved Design

**Files:**
- Create: `docs/plans/2026-03-16-decoder-aggregator-design.md`
- Create: `docs/plans/2026-03-16-decoder-aggregator-implementation.md`

**Step 1: Write the design summary**

- Record goals, non-goals, raw and standard topic contracts, profile model, aggregation behavior, and failure handling.

**Step 2: Save the implementation plan**

- Record exact file targets, test strategy, and rollout notes.

### Task 2: Add Failing Decoder And Aggregator Tests

**Files:**
- Create: `services/decoder_aggregator/tests/test_profiles.py`
- Create: `services/decoder_aggregator/tests/test_aggregator.py`

**Step 1: Write failing decode tests**

- Add tests for sample payloads from the vendor docs:
  - suspended solids float decode
  - COD decode
  - turbidity decode
  - ammonia decode

**Step 2: Run tests to verify red**

Run: `python3 -m unittest discover -s services/decoder_aggregator/tests -v`

Expected: import or implementation failures

### Task 3: Implement Pure Decode Logic

**Files:**
- Create: `services/decoder_aggregator/decoder_aggregator/__init__.py`
- Create: `services/decoder_aggregator/decoder_aggregator/profiles.py`
- Create: `services/decoder_aggregator/decoder_aggregator/modbus.py`

**Step 1: Implement frame parsing and CRC helpers**

- Parse `query + response`
- Validate CRC
- Extract address, function, byte count, and data bytes

**Step 2: Implement profile decoders**

- Decode all four supported sensor families
- Keep ammonia `ph` compensation out of published metrics

**Step 3: Re-run unit tests**

Run: `python3 -m unittest discover -s services/decoder_aggregator/tests -v`

Expected: decode tests pass, aggregation tests still fail

### Task 4: Implement Minute Aggregation

**Files:**
- Create: `services/decoder_aggregator/decoder_aggregator/aggregation.py`

**Step 1: Write failing aggregation tests**

- Verify sum/count averaging
- Verify flush cutoff after delay
- Verify closed windows only flush once

**Step 2: Implement minimal aggregation**

- Add minute bucket state
- Add `record()` and `flush_ready()` behavior

**Step 3: Re-run unit tests**

Run: `python3 -m unittest discover -s services/decoder_aggregator/tests -v`

Expected: all pure-logic tests pass

### Task 5: Implement Config And Runtime Service

**Files:**
- Create: `services/decoder_aggregator/decoder_aggregator/config.py`
- Create: `services/decoder_aggregator/decoder_aggregator/service.py`
- Create: `services/decoder_aggregator/decoder_aggregator/__main__.py`
- Create: `services/decoder_aggregator/config/devices.json`
- Create: `services/decoder_aggregator/config/devices.example.json`
- Create: `services/decoder_aggregator/requirements.txt`
- Create: `services/decoder_aggregator/Dockerfile`

**Step 1: Implement JSON config loading**

- Validate required keys
- Index profiles by raw source `device_id`
- Validate merged-output metric collisions

**Step 2: Implement MQTT runtime**

- Subscribe to raw topic pattern
- Decode and aggregate on incoming messages
- Publish ready minute-average JSON to standard topic

**Step 3: Add startup validation**

- Fail fast when config is invalid
- Log unknown-device raw messages without crashing

### Task 6: Wire Compose And EMQX ACLs

**Files:**
- Modify: `docker-compose.yml`
- Modify: `env/test.env.example`
- Modify: `env/prod.env.example`
- Modify: `scripts/stack.sh`

**Step 1: Add the new service to Compose**

- Mount config file
- Connect to the existing Docker network
- Use internal MQTT TCP listener

**Step 2: Add env knobs**

- Add decoder service credentials and runtime settings

**Step 3: Extend EMQX security setup**

- Allow device user to publish raw topics
- Create decoder user with raw subscribe and standard publish ACLs

### Task 7: Update Docs

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/MQTT_TIMESCALE_V1_SPEC.md`
- Modify: `docs/DATABASE_SCHEMA.md`

**Step 1: Document the two-layer topic model**

- raw topic for protocol adaptation
- standard topic for DB ingest

**Step 2: Document minute-average storage behavior**

- clarify that this decoder path stores minute averages only

### Task 8: Verify End-To-End Readiness

**Files:**
- No additional code files

**Step 1: Run unit tests**

Run: `python3 -m unittest discover -s services/decoder_aggregator/tests -v`

**Step 2: Validate Compose**

Run: `docker compose --project-directory /root/iot-stack -f /root/iot-stack/docker-compose.yml config`

**Step 3: If dependencies are available, build the decoder image**

Run: `docker compose --project-directory /root/iot-stack -f /root/iot-stack/docker-compose.yml build decoder-aggregator`

**Step 4: Record residual risk**

- runtime MQTT dependency resolution
- current-minute loss on service restart
- need for real device profile configuration before production use
