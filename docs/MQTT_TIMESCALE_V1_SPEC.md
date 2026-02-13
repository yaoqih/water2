# MQTT -> Timescale V1 协议规范

> 本文是“协议与入库契约”。
> 部署步骤见 `README.md`，架构背景见 `docs/ARCHITECTURE.md`，数据库细节见 `docs/DATABASE_SCHEMA.md`。

## 1. 规范目标

定义设备到数据库的唯一数据契约，保证：

- Topic 可解析
- 设备身份可校验
- Payload 可被稳定落库
- 历史行为可追踪

## 2. Topic 规范

### 2.1 上行遥测

`water/v1/{plant_id}/{point_id}/{device_id}/telemetry`

### 2.2 下行命令

`water/v1/{plant_id}/{point_id}/{device_id}/cmd/{name}`

## 3. 客户端身份规范

必须满足：

`MQTT Client ID == topic 中的 {device_id}`

示例：

- Topic：`water/v1/plant_a/inlet_01/dev_a_in_01/telemetry`
- Client ID：`dev_a_in_01`

### 3.1 ID 命名最佳实践（厂站/点位/设备）

目标：可读、可检索、可长期稳定。

- 字符集：仅用 `a-z0-9_`（避免空格、中文、大小写混用）
- 语义稳定：ID 只表达“身份”，不放易变信息（如临时项目名）
- 全局唯一：`plant_id/point_id/device_id` 在各自表内唯一
- 一致前缀：推荐按厂站分组，便于筛选与批量运维

推荐模板：

- `plant_id`：`plant_{city_or_region}_{site}`
- `point_id`：`pt_{site}_{inlet|outlet|line}`
- `device_id`：`dev_{site}_{point}_{nn}`

示例：

- `plant_cqbb_liaoning53`
- `pt_cqbb_liaoning53_inlet`
- `pt_cqbb_liaoning53_outlet`
- `dev_cqbb_liaoning53_inlet_01`

说明：地址可作为展示名称（如 `plant_name` / `point_name`），不要作为主键 ID。

## 4. Payload 规范（强约束）

### 4.1 允许格式

仅允许扁平 JSON（键值对）。

示例：

```json
{"cod": 36.5, "ph": 7.21, "turbidity": 12.8}
```

### 4.2 禁止格式

以下任一情况均拒绝：

- 非 JSON 对象
- 旧嵌套结构 `metrics`
- 字段 `msg_id`
- 字段 `seq`
- value 不可转数值

## 5. QoS 建议

- 推荐：`QoS 1`
- 可用：`QoS 2`

说明：QoS2 仅覆盖 MQTT 会话级，不等于 Broker -> DB exactly-once。

## 6. 服务端入库契约

函数：

- `ingest_telemetry(topic text, payload jsonb, clientid text, qos int)`
- `ingest_telemetry(topic text, payload text, clientid text, qos int)`（兼容模式）

校验顺序：

1. topic 必须匹配 V1 格式
2. `device_id == clientid`
3. payload 必须可解析为扁平 JSON（兼容模式允许 `{pow:12.2,RSSI:15}` 这类 bare key 文本）
4. payload 不得包含 `metrics/msg_id/seq`
5. 设备必须存在、启用且与 topic 的 plant/point/device 一致

写入行为：

- 服务端生成 `msg_id`
- 原样写入 `raw_message`
- 每个指标拆行为 `metric_sample`

## 7. EMQX 规则契约

Rule SQL：

```sql
SELECT * FROM "water/v1/+/+/+/telemetry"
```

Action SQL：

```sql
SELECT ingest_telemetry(${topic}, ${payload}, ${clientid}, ${qos});
```

资源命名：

- Connector：`timescale:ts_conn_water_v1`
- Action：`timescale:ts_ingest_telemetry_water_v1`
- Rule：`rule_water_v1_telemetry`

## 8. ACL 基线

- 允许发布：`water/v1/+/+/+/telemetry`
- 允许订阅：`water/v1/+/+/+/cmd/+`
- 其余拒绝：`#`

## 9. 协议相关数据对象

- `raw_message`：保留原始消息（含服务端 `msg_id`）
- `metric_sample`：按指标展开的时序明细

完整数据库字段、索引、视图设计见：`docs/DATABASE_SCHEMA.md`。

## 10. 示例

```bash
mosquitto_pub \
  -h water.blenet.top -p 8883 \
  --cafile /etc/ssl/certs/ca-certificates.crt \
  -u device_user -P 'your_password' \
  -i dev_a_in_01 \
  -t water/v1/plant_a/inlet_01/dev_a_in_01/telemetry \
  -m '{"cod":36.5,"ph":7.21}' -q 1
```
