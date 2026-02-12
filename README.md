# iot-stack（EMQX + TimescaleDB + Grafana）

提供一套可直接运行的 V1 链路模板：

`Device -> EMQX -> TimescaleDB -> Grafana`

并内置管理面：

`Grafana(7页：6个管理页+1个监测页) + PostgREST(admin_api)`

## 文档分工

- `README.md`：运行手册
- `docs/SCRIPTS.md`：脚本速查与常见报错排查
- `docs/ARCHITECTURE.md`：架构边界与数据流
- `docs/MQTT_TIMESCALE_V1_SPEC.md`：协议规范
- `docs/DATABASE_SCHEMA.md`：数据库设计
- `docs/CONTROL_PLANE_GRAFANA_POSTGREST.md`：管理面实现
- `docs/GRAFANA_SQL_AUDIT_2026-02-12.md`：Grafana/页面/SQL/文档专项审计

## 1) 双环境模型（prod/test）

本仓库支持并行运行两套环境：

- `prod`：固定读 `env/prod.env`
- `test`：固定读 `env/test.env`

隔离方式：

- 独立 Compose Project（默认 `iot-prod` / `iot-test`）
- 独立容器名（通过 `STACK_NAME`）
- 独立端口（建议 test 全部走高位端口 + 本机绑定）
- 独立密码/Token

## 2) 快速启动

```bash
cd /root/iot-stack

# 生产环境
cp env/prod.env.example env/prod.env
# 修改 env/prod.env 中密码、域名、POSTGREST_ADMIN_TOKEN

# 测试环境
cp env/test.env.example env/test.env
# 修改 env/test.env 中密码、域名、端口

# 启动测试环境（推荐先验证）
./scripts/stack.sh release --env test --fresh

# 测试通过后发布生产
./scripts/stack.sh release --env prod
```

说明：

- `--fresh` 会执行 `down -v`，清空该环境历史卷
- 所有命令都要求显式 `--env <prod|test>`
- 统一入口为 `scripts/stack.sh`

## 3) 脚本命令（入口）

- 统一入口：`./scripts/stack.sh`
- 速查与报错排查：`docs/SCRIPTS.md`

## 4) 脚本职责（精简后）

推荐只使用一个脚本：

- `scripts/stack.sh`：统一入口（`up` / `configure` / `release` / `tls`）

入口子命令说明：

- `up`：仅处理容器生命周期（`pull/up/down`）
- `configure`：运行期配置收敛（自动重放 DB schema + 权限收敛 + Grafana/EMQX 配置 + Grafana Team/Folder ACL）
- `release`：先 `up` 再 `configure`
- `tls issue`：申请证书并部署到各服务
- `tls deploy`：部署已有证书并重启相关服务

## 5) 访问地址（默认模板）

### prod（参考 `env/prod.env` / `env/prod.env.example`）

- EMQX Dashboard（HTTPS）：`https://${TLS_DOMAIN}:18084`
- Grafana（HTTPS）：`https://${TLS_DOMAIN}:443`
- MQTT TLS：`${TLS_DOMAIN}:8883`
- EMQX API（本机 HTTP）：`http://127.0.0.1:18083/api/v5`
- PostgREST 管理 API（本机 HTTP）：`http://127.0.0.1:3001`

### test（参考 `env/test.env.example`）

- EMQX Dashboard（HTTPS）：`https://127.0.0.1:28084`
- Grafana（HTTPS）：`https://127.0.0.1:2443`
- MQTT TLS：`127.0.0.1:18883`
- EMQX API（本机 HTTP）：`http://127.0.0.1:28083/api/v5`
- PostgREST 管理 API（本机 HTTP）：`http://127.0.0.1:23001`

> PostgREST 请求头需带：`x-admin-token`。

## 6) 管理面说明

- 页面与交互细节：`docs/CONTROL_PLANE_GRAFANA_POSTGREST.md`
- 当前管理页 UID：
  - `iot-v1-admin-home`
  - `iot-v1-admin-plant`
  - `iot-v1-admin-point`
  - `iot-v1-admin-device`
  - `iot-v1-admin-metric`
  - `iot-v1-admin-export`
  - `iot-v1-plant-monitor`

- Admin CRUD 页面已改为 Jsonnet 模板化生成（Grafana as code）：
  - 模板：`grafana/provisioning/dashboards/jsonnet/admin.libsonnet`
  - 入口：`grafana/provisioning/dashboards/jsonnet/admin.main.jsonnet`
  - 生成：`./scripts/generate_admin_dashboards.sh`
  - 校验是否最新：`./scripts/generate_admin_dashboards.sh --check`
  - 依赖命令：`jsonnet`（或 `go-jsonnet`）、`jq`
  - 生成器默认统一了 `row link` 的 URL 编码（`:percentencode`）与编辑查询变量转义（`:sqlstring`）
- Grafana 数据源已拆分：
  - `TimescaleDB-RO`：读查询默认数据源
  - `TimescaleDB-Admin`：仅供管理页写入动作（`admin_api` RPC）使用

## 7) 设备接入说明

- 协议与入库契约：`docs/MQTT_TIMESCALE_V1_SPEC.md`
- 核心约束：`MQTT Client ID == Topic 中 {device_id}`

## 8) TLS 证书

首次签发：

```bash
./scripts/stack.sh tls issue --env prod water.blenet.top
# 或测试环境
./scripts/stack.sh tls issue --env test test.water.blenet.top
```

续期 hook（手动触发）：

```bash
./scripts/stack.sh tls deploy --env prod water.blenet.top
```

## 9) 快速验收

```bash
# 查看两个环境状态
docker compose --env-file env/prod.env -p iot-prod ps
docker compose --env-file env/test.env -p iot-test ps

# 测试环境健康检查
curl -k https://127.0.0.1:28084/api/v5/status
curl -k https://127.0.0.1:2443/api/health
```

PostgREST 验证（test）：

```bash
set -a; source env/test.env; set +a
curl -sS -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  "http://127.0.0.1:${POSTGREST_PORT}/v_control_home"
```

MQTT 发布验证（test）：

```bash
set -a; source env/test.env; set +a

# 先创建测试对象（确保设备存在且路径匹配）
curl -sS -X POST -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{"p_plant_id":"plant_test","p_plant_name":"Plant Test","p_timezone":"Asia/Shanghai"}' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_plant"

curl -sS -X POST -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{"p_point_id":"pt_test_inlet","p_plant_id":"plant_test","p_point_type":"inlet","p_point_name":"Inlet"}' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_point"

curl -sS -X POST -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{"p_device_id":"dev_test_01","p_point_id":"pt_test_inlet","p_report_interval_sec":60,"p_align_mode":"floor","p_enabled":true}' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_device"

mosquitto_pub -h 127.0.0.1 -p "${EMQX_MQTT_PORT}" \
  --cafile /etc/ssl/certs/ca-certificates.crt \
  --insecure \
  -u "${EMQX_MQTT_USERNAME}" -P "${EMQX_MQTT_PASSWORD}" \
  -i dev_test_01 \
  -t water/v1/plant_test/pt_test_inlet/dev_test_01/telemetry \
  -m '{"cod":38.8,"ph":7.4}' -q 1

# 可选：检查是否落库成功
docker compose --env-file env/test.env -p iot-test exec -T timescaledb \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
  "SELECT device_id,metric,value_num FROM metric_sample WHERE device_id='dev_test_01' ORDER BY ingest_ts DESC LIMIT 4;"
```
