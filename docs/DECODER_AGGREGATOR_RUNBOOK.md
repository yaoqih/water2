# Decoder Aggregator Runbook

## Purpose

This runbook covers the remaining manual inputs required to enable the raw-hex decoder path:

- fill decoder source-device profiles
- create logical plant/point/device records
- configure environment secrets
- switch the upload module to raw topic publishing
- run a test-stack smoke check

## 1. Required Parameters

### 1.1 Environment Parameters

Fill these in `env/test.env` and `env/prod.env`:

| Key | Required | Meaning | Example |
| --- | --- | --- | --- |
| `EMQX_DECODER_USERNAME` | yes | MQTT username used by `decoder-aggregator` | `decoder_user_test` |
| `EMQX_DECODER_PASSWORD` | yes | MQTT password used by `decoder-aggregator` | `change_me_decoder_test` |
| `DECODER_MQTT_HOST` | usually no | Internal broker host | `emqx` |
| `DECODER_MQTT_PORT` | usually no | Internal broker TCP port | `1883` |
| `DECODER_RAW_TOPIC` | usually no | Raw subscription pattern | `water/raw/v1/+/+/+/telemetry` |
| `DECODER_SUBSCRIBER_CLIENT_ID` | yes | Stable client ID for decoder subscriber | `decoder_aggregator_test_sub` |
| `DECODER_SUBSCRIBE_QOS` | no | Raw-topic subscribe QoS | `1` |
| `DECODER_PUBLISH_QOS` | no | Standard-topic publish QoS | `1` |
| `DECODER_FLUSH_DELAY_SEC` | no | Delay after minute boundary before flush | `5` |
| `DECODER_KEEPALIVE_SEC` | no | MQTT keepalive | `30` |
| `DECODER_FLUSH_POLL_SEC` | no | Flush loop poll interval | `1.0` |
| `DECODER_LOG_LEVEL` | no | Service log level | `INFO` |

### 1.2 Device Metadata Parameters

Each logical output device still needs normal control-plane metadata:

| Field | Required | Meaning |
| --- | --- | --- |
| `plant_id` | yes | Plant identifier |
| `plant_name` | yes | Plant display name |
| `point_id` | yes | Point identifier |
| `point_type` | yes | `inlet` or `outlet` |
| `point_name` | yes | Point display name |
| `device_id` | yes | Logical device identifier; must match standard topic and republish client ID |
| `report_interval_sec` | yes | Recommended `60` |
| `align_mode` | yes | Recommended `floor` |
| `enabled` | yes | Recommended `true` |

### 1.3 Decoder Profile Parameters

Each decoder profile entry in `services/decoder_aggregator/config/devices.json` describes one sensor decoding rule. Multiple rules may share the same raw topic `source_device_id`.

| Field | Required | Meaning | Allowed values |
| --- | --- | --- | --- |
| `device_id` | yes | Decoder profile ID; only used inside config | free text, must be unique |
| `source_device_id` | no | Raw topic source device ID; default = `device_id` | free text |
| `profile_type` | yes | Sensor family decoder | `rs_ss`, `rs_cod`, `rs_zd_turbidity`, `rs_nhn_amnitro` |
| `sensor_range` | yes | Needed for scaling rules | see below |
| `modbus_match` | no | Use Modbus query frame fields to distinguish profiles on a shared topic | object |
| `target_device_id` | no | Logical output device ID; default = source `device_id` | free text |
| `publish_metrics` | no | Keep only these decoded fields | array of metric names |
| `metric_aliases` | no | Rename decoded fields before republish | object `{source_metric: output_metric}` |

`sensor_range` values by profile:

| `profile_type` | Allowed `sensor_range` |
| --- | --- |
| `rs_ss` | `200`, `1000`, `5000`, `20000` |
| `rs_cod` | `500` |
| `rs_zd_turbidity` | `50`, `200`, `1000`, `4000` |
| `rs_nhn_amnitro` | `10`, `100`, `1000` |

Note:

- `rs_ss` current implementation does not branch on range, but record the real range anyway for inventory consistency.
- `rs_nhn_amnitro` only publishes `amnitro` and optional `temperature`; it does not publish `ph`.
- If multiple source devices map to the same `target_device_id`, output metric names must remain unique after filtering/renaming.
- If multiple profiles share one `source_device_id`, each profile must define a distinct `modbus_match`.

### 1.4 Upload Module Parameters

These values must be configured in the upload module or its remote management page:

| Field | Required | Meaning |
| --- | --- | --- |
| MQTT broker host | yes | EMQX endpoint |
| MQTT broker port | yes | TLS or TCP port used by the module |
| MQTT username | yes | Existing device MQTT username |
| MQTT password | yes | Existing device MQTT password |
| MQTT topic | yes | Must be `water/raw/v1/{plant_id}/{point_id}/{source_device_id}/telemetry` |
| Payload format | yes | Pure hex string or raw binary Modbus frame bytes |
| Topic mode | yes | Shared single topic is supported; decoder distinguishes sensors by Modbus query frame |

## 2. Device Profile File Template

Edit [devices.json](/root/iot-stack/services/decoder_aggregator/config/devices.json).

Current deployed mapping for `plant_cqbb_liaoning53 / pt_cqbb_liaoning53_inlet / dev_cqbb_liaoning53_in_03`:

```json
{
  "devices": {
    "dev_cqbb_liaoning53_in_03_ss": {
      "source_device_id": "dev_cqbb_liaoning53_in_03",
      "profile_type": "rs_ss",
      "sensor_range": 20000,
      "modbus_match": {
        "address": 4,
        "function_code": 3,
        "start_register": 0
      },
      "target_device_id": "dev_cqbb_liaoning53_in_03",
      "publish_metrics": ["ss", "temperature"],
      "metric_aliases": {
        "temperature": "ss_temperature"
      }
    },
    "dev_cqbb_liaoning53_in_03_zd": {
      "source_device_id": "dev_cqbb_liaoning53_in_03",
      "profile_type": "rs_zd_turbidity",
      "sensor_range": 1000,
      "modbus_match": {
        "address": 1,
        "function_code": 3,
        "start_register": 0,
        "register_count": 2
      },
      "target_device_id": "dev_cqbb_liaoning53_in_03",
      "publish_metrics": ["turbidity", "temperature"],
      "metric_aliases": {
        "temperature": "turbidity_temperature"
      }
    },
    "dev_cqbb_liaoning53_in_03_cod": {
      "source_device_id": "dev_cqbb_liaoning53_in_03",
      "profile_type": "rs_cod",
      "sensor_range": 500,
      "modbus_match": {
        "address": 1,
        "function_code": 3,
        "start_register": 0,
        "register_count": 3
      },
      "target_device_id": "dev_cqbb_liaoning53_in_03",
      "publish_metrics": ["cod", "temperature", "turbidity"],
      "metric_aliases": {
        "temperature": "cod_temperature",
        "turbidity": "cod_turbidity"
      }
    },
    "dev_cqbb_liaoning53_in_03_nhn": {
      "source_device_id": "dev_cqbb_liaoning53_in_03",
      "profile_type": "rs_nhn_amnitro",
      "sensor_range": 100,
      "modbus_match": {
        "address": 2,
        "function_code": 3,
        "start_register": 0
      },
      "target_device_id": "dev_cqbb_liaoning53_in_03",
      "publish_metrics": ["amnitro", "temperature"],
      "metric_aliases": {
        "temperature": "amnitro_temperature"
      }
    }
  }
}
```

This produces the flat output payload shape:

```json
{
  "amnitro": 0.0,
  "amnitro_temperature": 0.0,
  "cod": 0.0,
  "cod_temperature": 0.0,
  "cod_turbidity": 0.0,
  "ss": 0.0,
  "ss_temperature": 0.0,
  "turbidity": 0.0,
  "turbidity_temperature": 0.0
}
```

Notes:

- 主指标仍然是 `ss/turbidity/cod/amnitro`。
- 各探头附带温度会用带前缀的新字段上传，避免多个 `temperature` 冲突。
- 氨氮手册里的 pH 补偿寄存器仍不作为测量值上传。
- 某个附带字段是否真正出现，取决于上传模块当前上报的原始帧是否包含对应寄存器；解码层不会补造不存在的数据。
- 当前这套站点使用单 raw topic：`water/raw/v1/plant_cqbb_liaoning53/pt_cqbb_liaoning53_inlet/dev_cqbb_liaoning53_in_03/telemetry`。
- 当前生产模块实测发来的是原始二进制帧，不是 ASCII hex 文本；decoder 已兼容这两种格式。

## 3. Control-Plane Upsert Commands

Assume you already copied `env/test.env.example` to `env/test.env` and filled real secrets.

```bash
set -a; source env/test.env; set +a
```

### 3.1 Create plant

```bash
curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{
    "p_plant_id":"<plant_id>",
    "p_plant_name":"<plant_name>",
    "p_timezone":"Asia/Shanghai"
  }' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_plant"
```

### 3.2 Create point

Repeat per point:

```bash
curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{
    "p_point_id":"<point_id>",
    "p_plant_id":"<plant_id>",
    "p_point_type":"<inlet_or_outlet>",
    "p_point_name":"<point_name>"
  }' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_point"
```

### 3.3 Create logical device

Only the logical output device needs to exist in the control plane. Raw source device IDs do not need DB records.

```bash
curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{
    "p_device_id":"<device_id>",
    "p_point_id":"<point_id>",
    "p_report_interval_sec":60,
    "p_align_mode":"floor",
    "p_enabled":true
  }' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_device"
```

### 3.4 Optional point-metric binding

If this logical device should become the dashboard source for these metrics on the inlet point, bind them explicitly:

```bash
curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{
    "p_point_id":"pt_cqbb_liaoning53_inlet",
    "p_metric":"ss",
    "p_device_id":"dev_cqbb_liaoning53_in_03"
  }' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_point_metric_source"

curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{
    "p_point_id":"pt_cqbb_liaoning53_inlet",
    "p_metric":"turbidity",
    "p_device_id":"dev_cqbb_liaoning53_in_03"
  }' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_point_metric_source"

curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{
    "p_point_id":"pt_cqbb_liaoning53_inlet",
    "p_metric":"cod",
    "p_device_id":"dev_cqbb_liaoning53_in_03"
  }' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_point_metric_source"

curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{
    "p_point_id":"pt_cqbb_liaoning53_inlet",
    "p_metric":"amnitro",
    "p_device_id":"dev_cqbb_liaoning53_in_03"
  }' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_point_metric_source"
```

## 4. Suggested Device Inventory Sheet

Prepare one row per decoder rule:

| plant_id | point_id | point_type | source_device_id | profile_id | profile_type | modbus_match | sensor_range | upload raw topic |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `plant_cqbb_liaoning53` | `pt_cqbb_liaoning53_inlet` | `inlet` | `dev_cqbb_liaoning53_in_03` | `dev_cqbb_liaoning53_in_03_ss` | `rs_ss` | `address=4,function=3,start=0` | `20000` | `water/raw/v1/plant_cqbb_liaoning53/pt_cqbb_liaoning53_inlet/dev_cqbb_liaoning53_in_03/telemetry` |
| `plant_cqbb_liaoning53` | `pt_cqbb_liaoning53_inlet` | `inlet` | `dev_cqbb_liaoning53_in_03` | `dev_cqbb_liaoning53_in_03_zd` | `rs_zd_turbidity` | `address=1,function=3,start=0,count=2` | `1000` | `water/raw/v1/plant_cqbb_liaoning53/pt_cqbb_liaoning53_inlet/dev_cqbb_liaoning53_in_03/telemetry` |
| `plant_cqbb_liaoning53` | `pt_cqbb_liaoning53_inlet` | `inlet` | `dev_cqbb_liaoning53_in_03` | `dev_cqbb_liaoning53_in_03_cod` | `rs_cod` | `address=1,function=3,start=0,count=3` | `500` | `water/raw/v1/plant_cqbb_liaoning53/pt_cqbb_liaoning53_inlet/dev_cqbb_liaoning53_in_03/telemetry` |
| `plant_cqbb_liaoning53` | `pt_cqbb_liaoning53_inlet` | `inlet` | `dev_cqbb_liaoning53_in_03` | `dev_cqbb_liaoning53_in_03_nhn` | `rs_nhn_amnitro` | `address=2,function=3,start=0` | `100` | `water/raw/v1/plant_cqbb_liaoning53/pt_cqbb_liaoning53_inlet/dev_cqbb_liaoning53_in_03/telemetry` |

## 5. Test-Stack Bring-Up

```bash
./scripts/stack.sh release --env test --fresh
```

Check decoder logs:

```bash
docker compose --env-file env/test.env -p iot-test logs -f decoder-aggregator
```

## 6. Raw Publish Smoke Test

Publish a raw hex sample to the exact source topic:

```bash
set -a; source env/test.env; set +a

mosquitto_pub -h 127.0.0.1 -p "${EMQX_MQTT_PORT}" \
  --cafile /etc/ssl/certs/ca-certificates.crt \
  --insecure \
  -u "${EMQX_MQTT_USERNAME}" -P "${EMQX_MQTT_PASSWORD}" \
  -i "<module_client_id>" \
  -t "water/raw/v1/plant_cqbb_liaoning53/pt_cqbb_liaoning53_inlet/dev_cqbb_liaoning53_in_03/telemetry" \
  -m "040300000002c45e0403044392772b7cb5" -q 1
```

Notes:

- The upload module client ID does not need to equal the raw `source_device_id` on the topic path.
- The decoder sidecar republishes the standard topic using `target_device_id=dev_cqbb_liaoning53_in_03` as publisher client ID.

## 7. Database Check

After waiting slightly more than one minute:

```bash
docker compose --env-file env/test.env -p iot-test exec -T timescaledb \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
  "SELECT device_id, metric, value_num, ingest_ts
   FROM metric_sample
   WHERE device_id = '<device_id>'
   ORDER BY ingest_ts DESC
   LIMIT 10;"
```

## 8. Done Criteria

The integration is ready when:

- `devices.json` contains all raw source sensor mappings
- the logical output device exists in the control plane
- upload module publishes to `water/raw/v1/.../telemetry`
- `decoder-aggregator` logs show successful decode and publish
- `metric_sample` contains 1-minute averages on the standard path
