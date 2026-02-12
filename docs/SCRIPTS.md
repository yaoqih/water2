# Scripts 速查

统一入口：`./scripts/stack.sh`

Admin dashboard 生成入口：`./scripts/generate_admin_dashboards.sh`

## 命令速查

```bash
# 查看帮助
./scripts/stack.sh --help

# 启动容器
./scripts/stack.sh up --env test
./scripts/stack.sh up --env prod

# 清理卷并重建
./scripts/stack.sh up --env test --fresh

# 仅应用运行期配置（Grafana + Grafana ACL + EMQX）
./scripts/stack.sh configure --env test

# 单独生成/校验 Admin CRUD dashboards（Jsonnet，含 Plant Monitor 导航同步）
./scripts/generate_admin_dashboards.sh
./scripts/generate_admin_dashboards.sh --check

# 一键发布（up + configure）
./scripts/stack.sh release --env test
./scripts/stack.sh release --env prod

# TLS 签发/部署
./scripts/stack.sh tls issue --env prod water.blenet.top
./scripts/stack.sh tls deploy --env prod water.blenet.top
```

## 最小发布流程

```bash
# 1) 准备配置（首次）
cp env/prod.env.example env/prod.env
cp env/test.env.example env/test.env

# 2) 先发 test（建议 fresh）
./scripts/stack.sh release --env test --fresh

# 3) 验证 test（示例）
curl -k https://127.0.0.1:28084/api/v5/status
curl -k https://127.0.0.1:2443/api/health

# 4) 发 prod
./scripts/stack.sh release --env prod

# 5) 首次启用 HTTPS（可选）
./scripts/stack.sh tls issue --env prod <your-domain>
```

说明：

- 日常迭代通常不需要 `--fresh`，仅在需要重置卷时使用。
- `release` 已包含 `up + configure`，一般不需要再单独执行两条命令。

## 常见报错排查

- `Missing env file: .../env/<env>.env`
  - 先复制模板：`cp env/<env>.env.example env/<env>.env`，再补全变量。

- `--env requires a value` / `Missing --env <prod|test>`
  - 所有命令都必须显式带 `--env prod` 或 `--env test`。

- `Missing required command: curl|jq|jsonnet|certbot`
  - 先安装依赖，再重试命令。

- `Grafana API is not ready`
  - 先确认容器健康：`docker compose --env-file env/test.env -p iot-test ps`。
  - 再执行：`./scripts/stack.sh configure --env test`。

- `db query error: pq: relation "admin_api.v_metric_export" does not exist`
  - 说明当前数据库 schema 未收敛到最新版本。
  - 执行：`./scripts/stack.sh configure --env test`（prod 用 `--env prod`）。

- `db query error: pq: relation "admin_api.v_metric_export_fields" does not exist`
  - 先确认名称拼写是 `v_metric_export_fields`（不是 `v_metric_export_tields`）。
  - 再执行：`./scripts/stack.sh configure --env test` 让 schema 与 PostgREST cache 自动收敛。

- `db query error: pq: column md.visible does not exist`
  - 说明数据库尚未应用 `metric_dict.visible` 迁移（代码已升级、库未升级）。
  - 执行：`./scripts/stack.sh configure --env test`（prod 用 `--env prod`）重放 `001_iot_init.sql`。
  - 如需立即修复，可手工执行：
    - `ALTER TABLE public.metric_dict ADD COLUMN IF NOT EXISTS visible boolean NOT NULL DEFAULT true;`
    - `UPDATE public.metric_dict SET visible = false WHERE metric IN ('pow','rssi');`

- `Failed to get EMQX token`
  - 检查 `env/<env>.env` 中 `EMQX_DASHBOARD_USER/EMQX_DASHBOARD_PASSWORD`。
  - 确认 EMQX 管理 API 地址 `EMQX_API_BASE` 可访问。

- 端口冲突（`bind ... already allocated`）
  - 修改 `env/<env>.env` 端口，或释放占用端口后重试。
