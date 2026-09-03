# IoT Stack 架构说明（V1）

> 协议见 `docs/MQTT_TIMESCALE_V1_SPEC.md`，数据库见 `docs/DATABASE_SCHEMA.md`，管理面见 `docs/CONTROL_PLANE_GRAFANA_POSTGREST.md`。

## 1. 目标与边界

目标：提供最小、稳定、可审计的数据链路与管理链路。

- 数据面：`Device/Gateway -> EMQX -> TimescaleDB -> Grafana`
- HTTP 数据面：`Public Water API -> water-api-collector -> EMQX -> TimescaleDB -> Grafana`
- 控制面：`Grafana/PostgREST -> admin_api -> PostgreSQL`

边界：

- 仅维护 V1，不做历史协议兼容
- 默认 TLS/HTTPS
- 设备无业务时间戳时统一使用 `ingest_ts`

## 2. 组件职责

### 2.1 EMQX

- MQTT 接入、鉴权、ACL
- 标准遥测 topic 的 Rule Engine 调用 `ingest_telemetry(...)`
- 承载原始 `raw` topic 与标准 `v1` topic

### 2.2 Decoder Aggregator

- 订阅 `water/raw/v1/.../telemetry`
- 按原始源设备 profile 解码原始十六进制 Modbus 载荷
- 支持同一 raw topic 下按 Modbus 查询帧特征区分多个传感器
- 对解码结果做 1 分钟均值聚合
- 支持将多路原始源设备映射并合并到 1 个逻辑 `target_device_id`
- 以逻辑 `target_device_id` 作为发布端 MQTT Client ID，回发标准 `water/v1/.../telemetry`

### 2.3 TimescaleDB

- 存储元数据与时序数据
- 承载 `admin_api`（视图/RPC/审计）

### 2.4 Water API Collector

- 按配置轮询公开水质 HTTP 接口，支持历史分页回填和持续增量拉取
- 将供应商字段映射为标准扁平遥测，并以逻辑设备 ID 作为 MQTT Client ID 发布
- 通过 `_observed_at` 传递源采集时间；重叠窗口由 `topic + source_ts` 幂等处理

### 2.5 Grafana

- 可观测看板
- 7 个页面（6 个管理页 + 1 个监测页）

### 2.6 PostgREST

- 暴露 `admin_api` 的 REST/RPC
- 通过 `x-admin-token` 做最小鉴权

## 3. 控制面写入路径

### 3.1 人工运维（Grafana 内）

`Form Panel -> SQL RPC(admin_api.*) -> audit_log`

### 3.2 自动化（PostgREST）

`Client -> /rpc/* -> admin_api.* -> audit_log`

两条路径共用同一套数据库函数，保证校验与审计一致。

## 4. 网络与端口面

### 4.1 对外（按 env 配置）

- MQTT TLS：`${EMQX_MQTT_PORT}`
- EMQX Dashboard HTTPS：`${EMQX_DASHBOARD_HTTPS_PORT}`
- Grafana HTTPS：`${GRAFANA_PORT}`
- PostgreSQL SSL：`${POSTGRES_PORT}`

### 4.2 本机管理面（按 env 配置）

- EMQX 管理 API（HTTP）：`${EMQX_DASHBOARD_HTTP_PORT}`
- PostgREST 管理 API（HTTP）：`${POSTGREST_PORT}`

## 5. 核心数据流

标准路径：

1. 设备发布 `water/v1/.../telemetry`
2. EMQX Rule 命中标准主题
3. EMQX Action 执行 `SELECT ingest_telemetry(...)`
4. DB 完成校验、写原始、拆分指标、更新时间
5. Grafana 查询 `metric_sample`

原始解码路径：

1. 上传模块发布 `water/raw/v1/.../telemetry`
2. `decoder-aggregator` 订阅原始主题
3. 按源设备 profile 解码；同一 topic 下可继续按 Modbus 查询帧选中具体 profile
4. 多路源设备可按 `target_device_id` 合并到同一分钟桶
5. `decoder-aggregator` 以逻辑 `target_device_id` 为发布端 Client ID，回发 `water/v1/.../telemetry`
6. 后续继续走标准路径入库

HTTP 拉取路径：

1. `water-api-collector` 从公开接口分页拉取数据
2. 每条记录映射为标准 JSON，并添加保留字段 `_observed_at`
3. 服务以逻辑设备 ID 发布到 `water/v1/.../telemetry`
4. EMQX 和 TimescaleDB 按标准路径处理；重复的源时间记录更新原始报文和指标

## 6. 自动化脚本分工

- `scripts/stack.sh`：统一入口（up/configure/release/tls）

说明：命令速查与常见报错排查见 `docs/SCRIPTS.md`。

## 7. 运行约束

- QoS2 不是数据库端 exactly-once 保证
- `msg_id` 用于追踪与排障
- 公网部署需配合安全组与最小暴露面
