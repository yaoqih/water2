# 管理面实现（Grafana + PostgREST）

> 目标：在 Grafana 内实现“可查可改可删”，同时保留 PostgREST 作为自动化 API。

> 若只关心命令，请直接看 `docs/SCRIPTS.md`。

## 1. 现状总览

当前已落地：

- `admin_api` 控制面 schema（视图 + RPC + 审计）
- Grafana 7 个页面（含导出页 + 监测大屏）
- PostgREST 管理 API（`x-admin-token` 鉴权）

关键文件：

- `postgres/initdb/002_admin_api.sql`
- `grafana/provisioning/dashboards/v1/iot-v1-admin-home.json`
- `grafana/provisioning/dashboards/v1/iot-v1-plant-monitor.json`
- `grafana/provisioning/dashboards/v1/iot-v1-admin-plant.json`
- `grafana/provisioning/dashboards/v1/iot-v1-admin-point.json`
- `grafana/provisioning/dashboards/v1/iot-v1-admin-device.json`
- `grafana/provisioning/dashboards/v1/iot-v1-admin-metric.json`
- `grafana/provisioning/dashboards/v1/iot-v1-admin-export.json`
- `docker-compose.yml`
- `scripts/stack.sh`

## 2. 页面（7 页）

Grafana 页面 UID：

1) `iot-v1-admin-home`（Control Home）
- 统计：厂站/点位/设备/在线数/24h 审计量
- 设备连接档案与最近审计

2) `iot-v1-admin-plant`（Plant）
- 厂站列表（每行含“编辑/删除”入口）
- 厂站编辑面板：新增/更新
- 支持下拉选择已有 ID 自动回填；也可手工输入新 ID

3) `iot-v1-admin-point`（Point）
- 点位列表（每行含“编辑/删除”入口）
- 点位编辑面板：新增/更新
- 支持下拉选择已有 ID 自动回填；也可手工输入新 ID

4) `iot-v1-admin-device`（Device）
- 设备列表（含连接档案字段，每行“编辑/删除”入口）
- 设备编辑面板：新增/更新
- 支持下拉选择设备/点位并自动回填

5) `iot-v1-admin-metric`（Metric Dictionary）
- 指标字典列表（每行含“编辑/删除”入口）
- 指标编辑面板：新增/更新
- 支持下拉选择已有指标并自动回填

6) `iot-v1-admin-export`（Export）
- 字段字典（含关联字段）统一来自 `admin_api.v_metric_export_fields`
- 导出预览支持按字段筛选（含 `plant/point/device/metric/unit/value_num`）
- 下载导出走后端固定 RPC：`admin_api.export_metric_rows(...)`（字段白名单 + 参数化过滤 + 服务端限流）
- 导出行数支持“不限”（由后端内部按安全策略限流）

7) `iot-v1-plant-monitor`（Plant Monitor）
- 左上角厂站选择，页面所有查询按 `plant_id` 过滤
- 顶部展示厂站实时指标统计
- 中部支持小时/日/周/月周期切换
- 左侧指标均值线列表 + 右侧入口/出口同图对比与蜡烛图
- 底部分列显示入口/出口告警信息

> 页面顶部均提供互相跳转导航。

## 3. 写入路径（两条）

### 3.1 Grafana 内部写入（已启用）

- 通过 `volkovlabs-form-panel` 表单面板提交
- 面板直接执行 SQL：`SELECT * FROM admin_api.xxx(...)`
- 适合人工运维场景（简洁、直观）

### 3.2 PostgREST API 写入（已启用）

- 通过 `/rpc/*` 调用同一套 `admin_api` 函数
- Header：`x-admin-token: <POSTGREST_ADMIN_TOKEN>`
- 适合脚本/CI/CD/外部系统联动

### 3.3 运行时权限边界（最小权限）

- PostgREST 登录账号：`iot_postgrest_authenticator`
  - 仅用于建立连接并切换到 `iot_api_editor` 能力域
  - 不直接持有 `public` 表写权限
- EMQX Timescale connector 账号：`iot_ingest_executor`
  - 仅具备 `ingest_telemetry` 所需最小读写权限
  - 不具备 `admin_api` 写入权限
- Grafana 读账号：`GRAFANA_DB_RO_USER`
  - 对应数据源：`TimescaleDB-RO`（默认）
  - 仅具备 `SELECT`（`public` 指定表 + `admin_api` 指定视图）
- Grafana 管理账号：`GRAFANA_DB_ADMIN_USER`
  - 对应数据源：`TimescaleDB-Admin`
  - 在 RO 权限基础上额外具备 `admin_api` 写 RPC 的 `EXECUTE`

> 上述账号和授权由 `scripts/stack.sh configure --env <prod|test>` 统一配置并幂等收敛。

### 3.4 Grafana 按人分权（Team + Folder ACL）

- Folder（默认拆分）：
  - 读看板：`IoT`（`GRAFANA_VIEWER_FOLDER_NAME`，兼容默认 `GRAFANA_DASHBOARD_FOLDER`）
  - 管理看板：`IoT-Admin`（`GRAFANA_ADMIN_FOLDER_NAME`）
- Team（默认）：
  - 管理：`iot-admin`（可通过 `GRAFANA_TEAM_ADMIN_NAME` 覆盖）
  - 只读：`iot-viewer`（可通过 `GRAFANA_TEAM_VIEWER_NAME` 覆盖）
- 可选只读登录账号（自动创建/收敛）：
  - 用户名：`GRAFANA_VIEWER_USER`
  - 密码：`GRAFANA_VIEWER_PASSWORD`
  - 账号会自动加入 `iot-viewer` team，并设置组织角色 `Viewer`
- ACL 收敛：
  - `IoT`：`iot-admin` => `Edit`，`iot-viewer` => `View`
  - `IoT-Admin`：仅 `iot-admin` => `Edit`
  - Dashboard ACL：对读看板/管理看板分别下发显式权限，避免继承链漂移
  - 配置由 `scripts/stack.sh configure --env <prod|test>` 自动下发
- 导航绑定脚本写回 dashboard 时会显式带 `folderUid`，避免漂移到 `General`
- 文件 provisioning 也按目录拆分：
  - `grafana/provisioning/dashboards/viewer` -> `IoT`
  - `grafana/provisioning/dashboards/admin` -> `IoT-Admin`
- Grafana UI 收敛：关闭 Explore（`GF_EXPLORE_ENABLED=false`），并显式禁止 viewer 编辑（`GF_USERS_VIEWERS_CAN_EDIT=false`）

### 3.5 Grafana 数据源分权（RO/Admin）

- 默认查询走 `TimescaleDB-RO`
- 管理页提交/删除动作走 `TimescaleDB-Admin`
- 导出页与监测页只使用 `TimescaleDB-RO`
- 运行配置入口：`scripts/stack.sh configure --env <prod|test>`

具体 DB 授权清单以 `docs/DATABASE_SCHEMA.md` 的“运行时账号与权限边界”为准。

### 3.6 Library Panel（已启用：导航）

- 已将“导航”抽为两套 Library Panel：
  - 管理导航：`IoT Admin Navigation`（含 CRUD 入口）
  - 只读导航：`IoT Viewer Navigation`（仅总览/导出/监测）
- 由脚本自动创建/更新并按看板类型绑定：`scripts/stack.sh configure --env <prod|test>`
- 当前未将“操作状态”抽为 Library Panel（各看板变量不同，直接复用会丢上下文）

### 3.7 Admin CRUD 看板生成（Jsonnet）

- 模板：`grafana/provisioning/dashboards/jsonnet/admin.libsonnet`
- 入口：`grafana/provisioning/dashboards/jsonnet/admin.main.jsonnet`
- 生成脚本：`scripts/generate_admin_dashboards.sh`
- `scripts/stack.sh configure --env <prod|test>` 会先执行 `--check`，若不一致会自动重生成

## 4. 交互约定（当前版本）

- 列表页每一行提供 `编辑/删除` 链接：`编辑` 进入编辑态，`删除` 直接执行删除流程
- 删除入口统一使用列表行内“删除”链接（减少冗余控件）
- 行内“删除”会先弹确认，再执行删除并刷新列表
- 删除成功 toast 显示对象 ID 与级联数量（厂站/点位），并自动回到空编辑态
- 删除后自动刷新列表，并在表格上方“状态条”显示最近删除结果（同时保留 toast）
- 新增时可直接在 `*_id（可新建）` 字段输入新 ID

## 5. PostgREST 资源

### 5.1 只读视图

- `/v_control_home`
- `/v_plant_list`
- `/v_point_list`
- `/v_device_list`
- `/v_metric_dict`
- `/v_metric_export`
- `/v_metric_export_fields`
- `/v_device_conn_profile`
- `/v_audit_log`

> 为避免 URL 过长，建议 `select` 字段控制在 20 列以内，并始终带时间范围与 `limit`。

导出接口说明（推荐）：

- Grafana 导出：调用 `admin_api.export_metric_rows(...)`（服务端白名单/限流）。
- `p_limit <= 0` 视为“不限”（由后端内部按安全策略限流）。
- URL 基础：`/v_metric_export`（用于直接 API 导出）
- 字段选择：`select=ingest_ts,plant_id,plant_name,device_id,metric,value_num,unit`
- 字段筛选：可对已暴露列使用 PostgREST 标准过滤，如
  - `plant_id=eq.plant_x`
  - `metric=in.(ph,cod)`
  - `plant_name=ilike.*示范*`
  - `value_num=gte.5`
- 时间范围：`ingest_ts=gte.<ISO8601>&ingest_ts=lt.<ISO8601>`
- 排序与行数：`order=ingest_ts.desc&limit=1000`
- CSV 导出：请求头 `Accept: text/csv`

### 5.2 写入 RPC

- `/rpc/upsert_plant`
- `/rpc/upsert_point`
- `/rpc/upsert_device`
- `/rpc/toggle_device`
- `/rpc/upsert_metric`
- `/rpc/export_metric_rows`
- `/rpc/delete_plant`
- `/rpc/delete_point`
- `/rpc/delete_device`
- `/rpc/delete_metric`

指标字典增强：

- `metric_dict` 增加 `alarm_low` / `alarm_high`
- `admin_api.v_metric_dict` 返回告警上下限
- `admin_api.upsert_metric` 支持上下限与展示开关（`visible`）参数
- `metric_dict` 增加 `visible`（默认 `true`），用于控制监控页指标是否展示

升级提示：

- 若历史库报错 `column md.visible does not exist`，执行 `./scripts/stack.sh configure --env <prod|test>` 以重放 schema。

## 6. 删除语义

- `delete_device(p_device_id)`：删除单设备
- `delete_point(p_point_id, p_force default false)`：
  - `force=false` 且存在设备时拒绝删除
  - `force=true` 先删点位下设备，再删点位
  - Grafana 行内删除默认走 `force=false`（更安全，避免误删级联）
- `delete_plant(p_plant_id, p_force default false)`：
  - `force=false` 且存在设备时拒绝删除
  - `force=true` 先删厂站下设备，再删厂站（点位随外键级联）
  - Grafana 行内删除默认走 `force=false`（更安全，避免误删级联）
- `delete_metric(p_metric)`：删除指标字典项

所有写入都会写入 `admin_api.audit_log`。

## 7. 快速验证

```bash
cd /root/iot-stack
set -a; source env/test.env; set +a

# 读：总览
curl -sS -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  "http://127.0.0.1:${POSTGREST_PORT}/v_control_home"

# 写：新增厂站
curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -d '{"p_plant_id":"plant_x","p_plant_name":"Plant X","p_timezone":"Asia/Shanghai"}' \
  "http://127.0.0.1:${POSTGREST_PORT}/rpc/upsert_plant"

# 读：导出字段字典
curl -sS -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  "http://127.0.0.1:${POSTGREST_PORT}/v_metric_export_fields?order=field_order.asc"

# 导出：CSV（字段可选 + 字段级筛选）
curl -sS \
  -H "x-admin-token: ${POSTGREST_ADMIN_TOKEN}" \
  -H "Accept: text/csv" \
  "http://127.0.0.1:${POSTGREST_PORT}/v_metric_export?select=ingest_ts,plant_id,point_id,device_id,metric,value_num,unit&ingest_ts=gte.2026-01-01T00:00:00Z&ingest_ts=lt.2026-12-31T00:00:00Z&metric=in.(ph,cod)&value_num=gte.0&order=ingest_ts.desc&limit=1000" \
  -o metric_export.csv
```

> 生产环境将 `env/test.env` + `iot-test` 替换为 `env/prod.env` + `iot-prod`。

## 8. 运行与变更注意事项

- `./scripts/stack.sh configure --env <prod|test>` 会自动重放 `postgres/initdb/001_iot_init.sql` 与 `postgres/initdb/002_admin_api.sql`，并自动重启 `postgrest` 刷新 schema cache。
- 当出现 `relation "admin_api.v_metric_export" does not exist` / `relation "admin_api.v_metric_export_fields" does not exist` 时，优先执行：

```bash
./scripts/stack.sh configure --env test
# 生产环境改为 --env prod
```

- 若 Grafana 首次启动时未下载完 `volkovlabs-form-panel`，可容器内执行一次：

```bash
docker compose --env-file env/test.env -p iot-test exec -T grafana \
  grafana cli --pluginsDir /var/lib/grafana/plugins plugins install volkovlabs-form-panel

docker compose --env-file env/test.env -p iot-test restart grafana
```
