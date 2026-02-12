# IoT Stack 架构说明（V1）

> 协议见 `docs/MQTT_TIMESCALE_V1_SPEC.md`，数据库见 `docs/DATABASE_SCHEMA.md`，管理面见 `docs/CONTROL_PLANE_GRAFANA_POSTGREST.md`。

## 1. 目标与边界

目标：提供最小、稳定、可审计的数据链路与管理链路。

- 数据面：`Device -> EMQX -> TimescaleDB -> Grafana`
- 控制面：`Grafana/PostgREST -> admin_api -> PostgreSQL`

边界：

- 仅维护 V1，不做历史协议兼容
- 默认 TLS/HTTPS
- 设备无业务时间戳时统一使用 `ingest_ts`

## 2. 组件职责

### 2.1 EMQX

- MQTT 接入、鉴权、ACL
- Rule Engine 调用 `ingest_telemetry(...)`

### 2.2 TimescaleDB

- 存储元数据与时序数据
- 承载 `admin_api`（视图/RPC/审计）

### 2.3 Grafana

- 可观测看板
- 7 个页面（6 个管理页 + 1 个监测页）

### 2.4 PostgREST

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

1. 设备发布 `water/v1/.../telemetry`
2. EMQX Rule 命中主题
3. EMQX Action 执行 `SELECT ingest_telemetry(...)`
4. DB 完成校验、写原始、拆分指标、更新时间
5. Grafana 查询 `metric_sample`

## 6. 自动化脚本分工

- `scripts/stack.sh`：统一入口（up/configure/release/tls）

说明：命令速查与常见报错排查见 `docs/SCRIPTS.md`。

## 7. 运行约束

- QoS2 不是数据库端 exactly-once 保证
- `msg_id` 用于追踪与排障
- 公网部署需配合安全组与最小暴露面
