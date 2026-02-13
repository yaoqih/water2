# Database Schema（TimescaleDB, V1）

> 部署步骤见 `README.md`，协议契约见 `docs/MQTT_TIMESCALE_V1_SPEC.md`。

> 脚本命令见 `docs/SCRIPTS.md`。

## 1. 设计目标

- 保留原始报文追溯（`raw_message`）
- 支持指标级时序分析（`metric_sample`）
- 提供可审计管理写入（`admin_api`）

## 2. 核心关系

`plant -> point -> device`

写入后：

- `raw_message`：每条上行报文 1 行
- `metric_sample`：每条报文按指标拆分 N 行

## 3. 数据面对象

### 3.1 元数据表

- `plant`
  - PK: `plant_id`
  - 字段：`plant_name`,`longitude`,`latitude`,`timezone`,`created_at`
- `point`
  - PK: `point_id`
  - FK: `plant_id -> plant(plant_id) ON DELETE CASCADE`
  - 字段：`point_type(inlet/outlet)`,`point_name`,`created_at`
- `device`
  - PK: `device_id`
  - FK: `point_id -> point(point_id) ON DELETE RESTRICT`
  - 字段：`report_interval_sec(1~3600)`,`align_mode(floor/round)`,`enabled`,`last_seen_at`,`created_at`
- `metric_dict`
  - PK: `metric`
  - 字段：`display_name`,`unit`,`visible`,`alarm_low`,`alarm_high`
  - 说明：`visible` 默认 `true`，用于控制监控大屏是否展示该指标
  - 默认阈值基线：
    - 初始化仅在 `metric_dict` 为空时执行，不覆盖已有字典数据
    - 参考 `GB 3838-2002`（地表水 III 类）：`ph`、`dissolvedOxygen`、`cod`、`amnitro`
    - 参考 `GB 18918-2002`（城镇污水处理厂一级 A）：`ss`
    - `watetT/waterEC/turbidity/temperature` 使用工程告警范围（用于水质监测与设备健康异常检测）

### 3.2 数据表

- `raw_message`
  - PK: `raw_id` identity
  - 字段：`ingest_ts`,`topic`,`msg_id`,`payload`
  - 索引：`raw_message_ts_idx`,`raw_message_topic_ts_idx`,`raw_message_topic_msg_idx`

- `metric_sample`（hypertable）
  - 时间列：`ingest_ts`
  - 字段：`plant_id`,`point_id`,`device_id`,`metric`,`value_num`,`raw_id`
  - chunk interval：`1 day`
  - 索引：`metric_sample_point_metric_ts_idx`,`metric_sample_device_metric_ts_idx`,`metric_sample_plant_metric_ts_idx`,`metric_sample_plant_metric_point_ts_idx`,`metric_sample_raw_id_idx`

### 3.3 数据面函数

`ingest_telemetry(topic text, payload jsonb, clientid text, qos int)`

`ingest_telemetry(topic text, payload text, clientid text, qos int)`（兼容模式）

职责：

1. 解析 topic 并提取 `plant_id/point_id/device_id`
2. 校验 `device_id == clientid`
3. 校验 payload 为扁平 JSON（兼容模式支持 bare key 文本并转换为 JSON；禁止 `metrics/msg_id/seq`）
4. 校验设备存在、启用、路径匹配
5. 服务端生成 `msg_id`
6. 写入 `raw_message`
7. 按设备 `report_interval_sec + align_mode(floor/round)` 对齐 `metric_sample.ingest_ts` 后拆分写入
8. 更新 `device.last_seen_at`

## 4. 控制面 schema：`admin_api`

### 4.1 审计

- 表：`admin_api.audit_log`
- 函数：`admin_api.write_audit(...)`
- 视图：`admin_api.v_audit_log`

### 4.2 控制面只读视图

- `admin_api.v_control_home`
- `admin_api.v_plant_list`
- `admin_api.v_point_list`
- `admin_api.v_device_list`
- `admin_api.v_metric_dict`
- `admin_api.v_metric_export`
- `admin_api.v_metric_export_fields`
- `admin_api.v_device_conn_profile`
- `admin_api.v_audit_log`

### 4.3 控制面 RPC

- Upsert：
  - `admin_api.upsert_plant(...)`
  - `admin_api.upsert_point(...)`
  - `admin_api.upsert_device(...)`
  - `admin_api.upsert_metric(p_metric, p_display_name, p_unit, p_alarm_low, p_alarm_high, p_visible)`
- 状态切换：
  - `admin_api.toggle_device(...)`
- Delete：
  - `admin_api.delete_plant(p_plant_id, p_force default false)`
  - `admin_api.delete_point(p_point_id, p_force default false)`
  - `admin_api.delete_device(p_device_id)`
  - `admin_api.delete_metric(p_metric)`
- Export：
  - `admin_api.export_metric_rows(p_fields, p_from, p_to, p_plant_id, p_point_id, p_device_id, p_metric, p_point_type, p_topic, p_limit)`
  - `p_plant_id/p_point_id/p_device_id/p_metric/p_point_type/p_topic` 支持逗号分隔多值
  - `p_metric/p_point_type` 会做小写归一化；`point_type` 仅允许 `all/inlet/outlet`
  - `p_limit <= 0` 视为“不限”（由后端内部按安全策略限流）

删除语义：

- `delete_point/plant` 在 `force=false` 且存在下游设备时拒绝删除
- `force=true` 时先删下游设备再删除对象
- 所有写入都会记录审计

### 4.4 鉴权与权限

- Pre-request：`admin_api.enforce_postgrest_token()`
- 角色：`iot_api_viewer`,`iot_api_editor`
- 原则：只授予视图查询 + RPC 执行

### 4.5 运行时账号与权限边界（2026-02 非兼容收敛）

当前运行时账号拆分为：

- `iot_postgrest_authenticator`
  - 用途：PostgREST `PGRST_DB_URI` 登录账号
  - 属性：`LOGIN` + `NOINHERIT`
  - 授权：`GRANT iot_api_editor TO iot_postgrest_authenticator`
  - 直接权限：仅 `CONNECT` 数据库 + `USAGE` on `admin_api`
  - 不授予：`public` schema 表写权限、superuser 能力

- `iot_ingest_executor`
  - 用途：EMQX Timescale connector 执行 `ingest_telemetry`
  - 授权：
    - `USAGE` on `public`
    - `SELECT` on `device/point/metric_dict`
    - `INSERT` on `raw_message/metric_sample`
    - `UPDATE(last_seen_at)` on `device`
    - `USAGE, SELECT` on `public` sequences
    - `EXECUTE` on `public.ingest_telemetry(...)`
  - 不授予：`admin_api` 写入权限、superuser 能力

- `GRAFANA_DB_RO_USER`（如 `iot_grafana_ro` / `iot_grafana_test_ro`）
  - 用途：Grafana 读数据源（`TimescaleDB-RO`）
  - 授权：`public`/`admin_api` 指定表与视图 `SELECT`
  - 不授予：`admin_api` 写入 RPC 执行权限、任意表写权限、superuser 能力

- `GRAFANA_DB_ADMIN_USER`（如 `iot_grafana` / `iot_grafana_test`）
  - 用途：Grafana 管理写数据源（`TimescaleDB-Admin`）
  - 授权：与 RO 账号同等读取权限 + `admin_api` 受控写 RPC 执行权限
  - 不授予：任意表写权限、superuser 能力

说明：

- `POSTGRES_USER` 仅用于容器初始化/运维，不参与应用运行时数据链路。
- 权限收敛逻辑由 `scripts/stack.sh configure --env <prod|test>` 统一执行并幂等生效。

## 5. 边界与建议

- 不做独立去重表；`msg_id` 用于追踪/排障
- 未内置 retention/compression policy，可按容量扩展
- 大规模场景建议补充：retention、continuous aggregate、冷热分层

## 6. Source of Truth

- 数据面：`postgres/initdb/001_iot_init.sql`
- 控制面：`postgres/initdb/002_admin_api.sql`

说明：管理页交互与 API 路径见 `docs/CONTROL_PLANE_GRAFANA_POSTGREST.md`。
