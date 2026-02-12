#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

die() {
  echo "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

load_env() {
  local env_name="$1"
  case "${env_name}" in
    prod|test) ;;
    *) die "Unsupported env: ${env_name} (expected: prod|test)" ;;
  esac

  local env_file="${STACK_DIR}/env/${env_name}.env"
  [ -f "${env_file}" ] || die "Missing env file: ${env_file}"

  set -a
  source "${env_file}"
  set +a

  STACK_ENV="${env_name}"
  STACK_ENV_FILE="${env_file}"
  COMPOSE_PROJECT_NAME="iot-${env_name}"

  export STACK_DIR STACK_ENV STACK_ENV_FILE COMPOSE_PROJECT_NAME
}

compose_stack() {
  docker compose \
    --project-directory "${STACK_DIR}" \
    --env-file "${STACK_ENV_FILE}" \
    -p "${COMPOSE_PROJECT_NAME}" \
    "$@"
}

usage() {
  cat <<EOF
Usage:
  $0 up        --env <prod|test> [--fresh]
  $0 configure --env <prod|test>
  $0 release   --env <prod|test> [--fresh]
  $0 tls issue --env <prod|test> [domain]
  $0 tls deploy --env <prod|test> [domain]

Commands:
  up         Start/recreate compose stack only
  configure  Apply runtime integrations only
  release    up + configure
  tls issue  Request cert via certbot then deploy certs
  tls deploy Deploy existing certs and restart services
EOF
}

parse_env_fresh_args() {
  STACK_ENV_ARG=""
  FRESH="false"
  while [ $# -gt 0 ]; do
    case "$1" in
      --env)
        [ $# -ge 2 ] || die "--env requires a value"
        STACK_ENV_ARG="$2"
        shift 2
        ;;
      --fresh)
        FRESH="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [ -n "${STACK_ENV_ARG}" ] || die "Missing --env <prod|test>"
}

parse_env_only_args() {
  STACK_ENV_ARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --env)
        [ $# -ge 2 ] || die "--env requires a value"
        STACK_ENV_ARG="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [ -n "${STACK_ENV_ARG}" ] || die "Missing --env <prod|test>"
}

print_stack_ready() {
  echo "Stack is ready"
  echo "Stack env            : ${STACK_ENV}"
  echo "Compose project      : ${COMPOSE_PROJECT_NAME}"
  echo "Env file             : ${STACK_ENV_FILE}"
  echo "EMQX Dashboard HTTPS : https://${TLS_DOMAIN}:${EMQX_DASHBOARD_HTTPS_PORT:-18084}"
  echo "EMQX API (local)     : ${EMQX_API_BASE:-http://127.0.0.1:${EMQX_DASHBOARD_HTTP_PORT:-18083}/api/v5}"
  echo "MQTT TCP (non-TLS)   : ${TLS_DOMAIN}:${EMQX_MQTT_TCP_PORT:-1883}"
  echo "MQTT TLS             : ${TLS_DOMAIN}:${EMQX_MQTT_PORT:-8883}"
  echo "Grafana HTTPS        : https://${TLS_DOMAIN}:${GRAFANA_PORT:-443}"
  echo "PostgREST API (local): http://127.0.0.1:${POSTGREST_PORT:-3001} (x-admin-token required)"
}

run_up() {
  parse_env_fresh_args "$@"
  load_env "${STACK_ENV_ARG}"

  if [ "${FRESH}" = "true" ]; then
    compose_stack down -v --remove-orphans
  fi

  compose_stack pull
  compose_stack up -d --remove-orphans
  print_stack_ready
}

TMP_DIR=""
EMQX_API_BASE=""
EMQX_AUTH=()

reconcile_db_schema() {
  : "${POSTGRES_USER:?POSTGRES_USER is required}"
  : "${POSTGRES_DB:?POSTGRES_DB is required}"

  local sql_file
  for sql_file in \
    "${STACK_DIR}/postgres/initdb/001_iot_init.sql" \
    "${STACK_DIR}/postgres/initdb/002_admin_api.sql"; do
    [ -f "${sql_file}" ] || die "Missing SQL file: ${sql_file}"
    compose_stack exec -T timescaledb psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" < "${sql_file}"
  done

  echo "DB schema reconciled (${STACK_ENV})"
}

configure_runtime_db_roles() {
  : "${POSTGRES_USER:?POSTGRES_USER is required}"
  : "${POSTGRES_DB:?POSTGRES_DB is required}"
  : "${POSTGREST_DB_USER:?POSTGREST_DB_USER is required}"
  : "${POSTGREST_DB_PASSWORD:?POSTGREST_DB_PASSWORD is required}"
  : "${EMQX_TS_DB_USER:?EMQX_TS_DB_USER is required}"
  : "${EMQX_TS_DB_PASSWORD:?EMQX_TS_DB_PASSWORD is required}"

  compose_stack exec -T timescaledb psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${POSTGREST_DB_USER}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L NOINHERIT', '${POSTGREST_DB_USER}', '${POSTGREST_DB_PASSWORD}');
  ELSE
    EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L', '${POSTGREST_DB_USER}', '${POSTGREST_DB_PASSWORD}');
    EXECUTE format('ALTER ROLE %I NOINHERIT', '${POSTGREST_DB_USER}');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${EMQX_TS_DB_USER}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${EMQX_TS_DB_USER}', '${EMQX_TS_DB_PASSWORD}');
  ELSE
    EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L', '${EMQX_TS_DB_USER}', '${EMQX_TS_DB_PASSWORD}');
  END IF;
END
\$\$;

REVOKE ALL ON DATABASE ${POSTGRES_DB} FROM ${POSTGREST_DB_USER};
REVOKE ALL ON DATABASE ${POSTGRES_DB} FROM ${EMQX_TS_DB_USER};

REVOKE ALL ON SCHEMA public FROM ${POSTGREST_DB_USER};
REVOKE ALL ON SCHEMA admin_api FROM ${POSTGREST_DB_USER};
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM ${POSTGREST_DB_USER};
REVOKE ALL ON ALL TABLES IN SCHEMA admin_api FROM ${POSTGREST_DB_USER};
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM ${POSTGREST_DB_USER};
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA admin_api FROM ${POSTGREST_DB_USER};

REVOKE ALL ON SCHEMA public FROM ${EMQX_TS_DB_USER};
REVOKE ALL ON SCHEMA admin_api FROM ${EMQX_TS_DB_USER};
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM ${EMQX_TS_DB_USER};
REVOKE ALL ON ALL TABLES IN SCHEMA admin_api FROM ${EMQX_TS_DB_USER};
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM ${EMQX_TS_DB_USER};
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA admin_api FROM ${EMQX_TS_DB_USER};

GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO ${POSTGREST_DB_USER};
GRANT USAGE ON SCHEMA admin_api TO ${POSTGREST_DB_USER};
GRANT iot_api_editor TO ${POSTGREST_DB_USER};

GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO ${EMQX_TS_DB_USER};
GRANT USAGE ON SCHEMA public TO ${EMQX_TS_DB_USER};
GRANT SELECT ON TABLE public.device, public.point, public.metric_dict, public.raw_message TO ${EMQX_TS_DB_USER};
GRANT INSERT ON TABLE public.raw_message, public.metric_sample TO ${EMQX_TS_DB_USER};
GRANT UPDATE (last_seen_at) ON TABLE public.device TO ${EMQX_TS_DB_USER};
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${EMQX_TS_DB_USER};
GRANT EXECUTE ON FUNCTION public.ingest_telemetry(TEXT, JSONB, TEXT, INT) TO ${EMQX_TS_DB_USER};
SQL

  echo "Runtime DB roles ready (${STACK_ENV})"
}

configure_grafana_db_roles() {
  : "${POSTGRES_USER:?POSTGRES_USER is required}"
  : "${POSTGRES_DB:?POSTGRES_DB is required}"
  : "${GRAFANA_DB_USER:?GRAFANA_DB_USER is required}"
  : "${GRAFANA_DB_PASSWORD:?GRAFANA_DB_PASSWORD is required}"

  local grafana_admin_user="${GRAFANA_DB_ADMIN_USER:-${GRAFANA_DB_USER}}"
  local grafana_admin_password="${GRAFANA_DB_ADMIN_PASSWORD:-${GRAFANA_DB_PASSWORD}}"
  local grafana_ro_user="${GRAFANA_DB_RO_USER:-${GRAFANA_DB_USER}_ro}"
  local grafana_ro_password="${GRAFANA_DB_RO_PASSWORD:-${GRAFANA_DB_PASSWORD}}"

  compose_stack exec -T timescaledb psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = '${grafana_admin_user}'
  ) THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${grafana_admin_user}', '${grafana_admin_password}');
  ELSE
    EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L', '${grafana_admin_user}', '${grafana_admin_password}');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = '${grafana_ro_user}'
  ) THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${grafana_ro_user}', '${grafana_ro_password}');
  ELSE
    EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L', '${grafana_ro_user}', '${grafana_ro_password}');
  END IF;
END
\$\$;

ALTER ROLE ${grafana_admin_user} CONNECTION LIMIT -1;
ALTER ROLE ${grafana_ro_user} CONNECTION LIMIT -1;

REVOKE ALL ON SCHEMA public FROM ${grafana_admin_user}, ${grafana_ro_user};
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM ${grafana_admin_user}, ${grafana_ro_user};
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM ${grafana_admin_user}, ${grafana_ro_user};
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM ${grafana_admin_user}, ${grafana_ro_user};

REVOKE ALL ON SCHEMA admin_api FROM ${grafana_admin_user}, ${grafana_ro_user};
REVOKE ALL ON ALL TABLES IN SCHEMA admin_api FROM ${grafana_admin_user}, ${grafana_ro_user};
REVOKE ALL ON ALL SEQUENCES IN SCHEMA admin_api FROM ${grafana_admin_user}, ${grafana_ro_user};
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA admin_api FROM ${grafana_admin_user}, ${grafana_ro_user};

GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO ${grafana_admin_user}, ${grafana_ro_user};
GRANT USAGE ON SCHEMA public TO ${grafana_admin_user}, ${grafana_ro_user};
GRANT USAGE ON SCHEMA admin_api TO ${grafana_admin_user}, ${grafana_ro_user};

GRANT SELECT ON TABLE
  public.raw_message,
  public.metric_sample,
  public.metric_dict,
  public.plant,
  public.point,
  public.device,
  admin_api.v_control_home,
  admin_api.v_plant_list,
  admin_api.v_point_list,
  admin_api.v_device_list,
  admin_api.v_metric_dict,
  admin_api.v_metric_export,
  admin_api.v_metric_export_fields,
  admin_api.v_device_conn_profile,
  admin_api.v_audit_log
TO ${grafana_admin_user}, ${grafana_ro_user};

GRANT EXECUTE ON FUNCTION
  admin_api.upsert_plant(TEXT, TEXT, NUMERIC, NUMERIC, TEXT),
  admin_api.upsert_point(TEXT, TEXT, TEXT, TEXT),
  admin_api.upsert_device(TEXT, TEXT, INT, TEXT, BOOLEAN),
  admin_api.toggle_device(TEXT, BOOLEAN),
  admin_api.upsert_metric(TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN),
  admin_api.export_metric_rows(TEXT[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INT),
  admin_api.delete_device(TEXT),
  admin_api.delete_point(TEXT, BOOLEAN),
  admin_api.delete_plant(TEXT, BOOLEAN),
  admin_api.delete_metric(TEXT)
TO ${grafana_admin_user};
SQL

  echo "Grafana DB roles ready (${STACK_ENV})"
}

configure_grafana_nav_panel() {
  : "${GRAFANA_ADMIN_USER:?GRAFANA_ADMIN_USER is required}"
  : "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD is required}"

  local grafana_url="${GRAFANA_URL:-https://127.0.0.1:${GRAFANA_PORT:-443}}"
  local viewer_folder_name="${GRAFANA_VIEWER_FOLDER_NAME:-${GRAFANA_DASHBOARD_FOLDER:-IoT}}"
  local admin_folder_name="${GRAFANA_ADMIN_FOLDER_NAME:-IoT-Admin}"
  local lib_uid_admin="lib_iot_admin_nav"
  local lib_name_admin="IoT Admin Navigation"
  local lib_uid_viewer="lib_iot_view_nav"
  local lib_name_viewer="IoT Viewer Navigation"
  local nav_config
  local nav_content_admin
  local nav_content_viewer
  nav_config="$(jsonnet "${STACK_DIR}/grafana/provisioning/dashboards/jsonnet/nav.libsonnet")"
  nav_content_admin="$(printf '%s' "${nav_config}" | jq -r '.admin_content // .content')"
  nav_content_viewer="$(printf '%s' "${nav_config}" | jq -r '.viewer_content // .content')"
  local dashboard_uids=(
    iot-v1-admin-home
    iot-v1-admin-plant
    iot-v1-admin-point
    iot-v1-admin-device
    iot-v1-admin-metric
    iot-v1-admin-export
    iot-v1-plant-monitor
  )

  api_get() {
    local path="$1"
    curl -ksS -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" "${grafana_url}${path}"
  }

  api_post() {
    local path="$1"
    local data_file="$2"
    curl -ksS -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -X POST "${grafana_url}${path}" \
      -d @"${data_file}"
  }

  api_patch() {
    local path="$1"
    local data_file="$2"
    curl -ksS -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -X PATCH "${grafana_url}${path}" \
      -d @"${data_file}"
  }

  echo "Checking Grafana health..."
  for _ in $(seq 1 30); do
    if api_get "/api/health" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  api_get "/api/health" >/dev/null 2>&1 || die "Grafana API is not ready: ${grafana_url}"

  resolve_folder_uid() {
    local folder_title="$1"
    local out_uid
    out_uid="$(api_get "/api/folders" | jq -r --arg title "${folder_title}" 'map(select(.title == $title)) | .[0].uid // empty')"
    if [ -z "${out_uid}" ]; then
      local folder_payload="${TMP_DIR}/folder_payload_$(printf '%s' "${folder_title}" | tr ' ' '_').json"
      jq -n --arg title "${folder_title}" '{title: $title}' > "${folder_payload}"
      out_uid="$(api_post "/api/folders" "${folder_payload}" | jq -r '.uid // empty')"
    fi
    [ -n "${out_uid}" ] || die "Unable to resolve Grafana folder uid for ${folder_title}"
    printf '%s\n' "${out_uid}"
  }

  local viewer_folder_uid
  local admin_folder_uid
  viewer_folder_uid="$(resolve_folder_uid "${viewer_folder_name}")"
  admin_folder_uid="$(resolve_folder_uid "${admin_folder_name}")"

  upsert_nav_library_panel() {
    local lib_uid="$1"
    local lib_name="$2"
    local lib_content="$3"
    local model_json="${TMP_DIR}/model_${lib_uid}.json"
    local create_payload="${TMP_DIR}/create_payload_${lib_uid}.json"
    local update_payload="${TMP_DIR}/update_payload_${lib_uid}.json"
    local get_out="${TMP_DIR}/library_get_${lib_uid}.json"
    local status_code

    jq -n --arg content "${lib_content}" '{
      title: "导航",
      type: "text",
      description: "IoT 导航",
      gridPos: {h: 2, w: 24, x: 0, y: 0},
      options: {mode: "markdown", content: $content}
    }' > "${model_json}"

    status_code="$(curl -k -sS -o "${get_out}" -w '%{http_code}' \
      -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      "${grafana_url}/api/library-elements/${lib_uid}")"

    if [ "${status_code}" = "200" ]; then
      local version
      version="$(jq -r '.result.version' "${get_out}")"
      jq -n \
        --arg name "${lib_name}" \
        --argjson version "${version}" \
        --slurpfile model "${model_json}" \
        '{name: $name, kind: 1, version: $version, model: $model[0]}' > "${update_payload}"
      api_patch "/api/library-elements/${lib_uid}" "${update_payload}" >/dev/null
    elif [ "${status_code}" = "404" ]; then
      jq -n \
        --arg uid "${lib_uid}" \
        --arg name "${lib_name}" \
        --slurpfile model "${model_json}" \
        '{uid: $uid, name: $name, kind: 1, folderId: 0, model: $model[0]}' > "${create_payload}"
      api_post "/api/library-elements" "${create_payload}" >/dev/null
    else
      cat "${get_out}" >&2
      die "Failed to query library panel ${lib_uid}, HTTP ${status_code}"
    fi
  }

  upsert_nav_library_panel "${lib_uid_admin}" "${lib_name_admin}" "${nav_content_admin}"
  upsert_nav_library_panel "${lib_uid_viewer}" "${lib_name_viewer}" "${nav_content_viewer}"

  local uid
  for uid in "${dashboard_uids[@]}"; do
    local dashboard_src="${STACK_DIR}/grafana/provisioning/dashboards/v1/${uid}.json"
    local dashboard_get="${TMP_DIR}/db_${uid}.json"
    local dashboard_new="${TMP_DIR}/db_${uid}_new.json"
    local dashboard_payload="${TMP_DIR}/db_${uid}_payload.json"
    local status_code

    if [ -f "${dashboard_src}" ]; then
      cp "${dashboard_src}" "${dashboard_get}"
    else
      status_code="$(curl -k -sS -o "${dashboard_get}" -w '%{http_code}' \
        -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        "${grafana_url}/api/dashboards/uid/${uid}")"
      if [ "${status_code}" != "200" ]; then
        echo "Skip dashboard ${uid}: source missing and API returned HTTP ${status_code}" >&2
        continue
      fi
      jq '.dashboard' "${dashboard_get}" > "${dashboard_get}.tmp"
      mv "${dashboard_get}.tmp" "${dashboard_get}"
    fi

    local target_folder_uid
    local target_lib_uid
    local target_lib_name
    case "${uid}" in
      iot-v1-admin-plant|iot-v1-admin-point|iot-v1-admin-device|iot-v1-admin-metric)
        target_folder_uid="${admin_folder_uid}"
        target_lib_uid="${lib_uid_admin}"
        target_lib_name="${lib_name_admin}"
        ;;
      *)
        target_folder_uid="${viewer_folder_uid}"
        target_lib_uid="${lib_uid_viewer}"
        target_lib_name="${lib_name_viewer}"
        ;;
    esac

    jq --arg luid "${target_lib_uid}" --arg lname "${target_lib_name}" '
      .id = null
      | .panels |= map(
          if (.title // "") == "导航" then
            . + {libraryPanel: {uid: $luid, name: $lname}}
          else
            .
          end
        )
    ' "${dashboard_get}" > "${dashboard_new}"

    jq -n --slurpfile dashboard "${dashboard_new}" --arg msg "sync dashboard from file and bind navigation library panel" --arg folder_uid "${target_folder_uid}" '{
      dashboard: $dashboard[0],
      folderUid: $folder_uid,
      overwrite: true,
      message: $msg
    }' > "${dashboard_payload}"

    api_post "/api/dashboards/db" "${dashboard_payload}" >/dev/null
  done

  echo "Grafana library panel bound (${STACK_ENV})"
}

configure_grafana_access_control() {
  : "${GRAFANA_ADMIN_USER:?GRAFANA_ADMIN_USER is required}"
  : "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD is required}"

  local grafana_url="${GRAFANA_URL:-https://127.0.0.1:${GRAFANA_PORT:-443}}"
  local viewer_folder_name="${GRAFANA_VIEWER_FOLDER_NAME:-${GRAFANA_DASHBOARD_FOLDER:-IoT}}"
  local admin_folder_name="${GRAFANA_ADMIN_FOLDER_NAME:-IoT-Admin}"
  local admin_team_name="${GRAFANA_TEAM_ADMIN_NAME:-iot-admin}"
  local viewer_team_name="${GRAFANA_TEAM_VIEWER_NAME:-iot-viewer}"
  local viewer_login="${GRAFANA_VIEWER_USER:-}"
  local viewer_password="${GRAFANA_VIEWER_PASSWORD:-}"

  api_get() {
    local path="$1"
    curl -ksS -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" "${grafana_url}${path}"
  }

  api_post() {
    local path="$1"
    local data_file="$2"
    curl -ksS -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -X POST "${grafana_url}${path}" \
      -d @"${data_file}"
  }

  add_team_member() {
    local team_id="$1"
    local user_id="$2"
    local label="$3"
    local payload="${TMP_DIR}/team_member_${team_id}_${user_id}.json"
    local out="${TMP_DIR}/team_member_${team_id}_${user_id}.out"
    local status_code

    jq -n --argjson user_id "${user_id}" '{userId: $user_id}' > "${payload}"
    status_code="$(
      curl -k -sS -o "${out}" -w '%{http_code}' \
        -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        -H 'Content-Type: application/json' \
        -X POST "${grafana_url}/api/teams/${team_id}/members" \
        -d @"${payload}"
    )"
    if [ "${status_code}" != "200" ] && ! grep -qi "already" "${out}"; then
      cat "${out}" >&2
      die "Failed to add ${label} to team ${team_id}, HTTP ${status_code}"
    fi
  }

  remove_team_member() {
    local team_id="$1"
    local user_id="$2"
    local out="${TMP_DIR}/team_member_delete_${team_id}_${user_id}.out"
    local status_code
    status_code="$(
      curl -k -sS -o "${out}" -w '%{http_code}' \
        -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        -X DELETE "${grafana_url}/api/teams/${team_id}/members/${user_id}"
    )"
    if [ "${status_code}" != "200" ] && [ "${status_code}" != "404" ]; then
      cat "${out}" >&2
      die "Failed to remove user ${user_id} from team ${team_id}, HTTP ${status_code}"
    fi
  }

  lookup_user_id() {
    local login="$1"
    local encoded
    encoded="$(jq -rn --arg s "${login}" '$s|@uri')"
    api_get "/api/users/lookup?loginOrEmail=${encoded}" | jq -r '.id // empty'
  }

  ensure_team() {
    local team_name="$1"
    local encoded_name
    local team_id
    encoded_name="$(jq -rn --arg s "${team_name}" '$s|@uri')"
    team_id="$(
      api_get "/api/teams/search?name=${encoded_name}" \
        | jq -r --arg name "${team_name}" '.teams[]? | select(.name == $name) | .id' \
        | head -n1
    )"
    if [ -z "${team_id}" ]; then
      local payload="${TMP_DIR}/team_${team_name}.json"
      jq -n --arg name "${team_name}" '{name: $name}' > "${payload}"
      team_id="$(api_post "/api/teams" "${payload}" | jq -r '.teamId // .id // empty')"
    fi
    [ -n "${team_id}" ] || die "Unable to resolve Grafana team id for ${team_name}"
    printf '%s\n' "${team_id}"
  }

  resolve_folder_uid() {
    local folder_title="$1"
    local out_uid
    out_uid="$(api_get "/api/folders" | jq -r --arg title "${folder_title}" 'map(select(.title == $title)) | .[0].uid // empty')"
    if [ -z "${out_uid}" ]; then
      local folder_payload="${TMP_DIR}/access_folder_payload_$(printf '%s' "${folder_title}" | tr ' ' '_').json"
      jq -n --arg title "${folder_title}" '{title: $title}' > "${folder_payload}"
      out_uid="$(api_post "/api/folders" "${folder_payload}" | jq -r '.uid // empty')"
    fi
    [ -n "${out_uid}" ] || die "Unable to resolve Grafana folder uid for ${folder_title}"
    printf '%s\n' "${out_uid}"
  }

  local viewer_folder_uid
  local admin_folder_uid
  viewer_folder_uid="$(resolve_folder_uid "${viewer_folder_name}")"
  admin_folder_uid="$(resolve_folder_uid "${admin_folder_name}")"

  local admin_team_id
  local viewer_team_id
  admin_team_id="$(ensure_team "${admin_team_name}")"
  viewer_team_id="$(ensure_team "${viewer_team_name}")"

  local org_users_json="${TMP_DIR}/org_users.json"
  api_get "/api/org/users" > "${org_users_json}"

  local admin_user_id
  admin_user_id="$(
    jq -r --arg login "${GRAFANA_ADMIN_USER}" '.[] | select(.login == $login) | .userId' "${org_users_json}" \
      | head -n1
  )"
  if [ -n "${admin_user_id}" ]; then
    add_team_member "${admin_team_id}" "${admin_user_id}" "${GRAFANA_ADMIN_USER}"
    remove_team_member "${viewer_team_id}" "${admin_user_id}"
  fi

  if [ -n "${viewer_login}" ] || [ -n "${viewer_password}" ]; then
    [ -n "${viewer_login}" ] || die "GRAFANA_VIEWER_USER is required when GRAFANA_VIEWER_PASSWORD is set"
    [ -n "${viewer_password}" ] || die "GRAFANA_VIEWER_PASSWORD is required when GRAFANA_VIEWER_USER is set"

    local viewer_user_id
    viewer_user_id="$(lookup_user_id "${viewer_login}" | head -n1)"
    if [ -z "${viewer_user_id}" ]; then
      local viewer_create_payload="${TMP_DIR}/viewer_create.json"
      local viewer_create_out="${TMP_DIR}/viewer_create.out"
      local viewer_create_status
      jq -n \
        --arg login "${viewer_login}" \
        --arg name "${viewer_login}" \
        --arg email "${viewer_login}@local" \
        --arg password "${viewer_password}" \
        '{name: $name, email: $email, login: $login, password: $password}' > "${viewer_create_payload}"
      viewer_create_status="$(
        curl -k -sS -o "${viewer_create_out}" -w '%{http_code}' \
          -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
          -H 'Content-Type: application/json' \
          -X POST "${grafana_url}/api/admin/users" \
          -d @"${viewer_create_payload}"
      )"
      if [ "${viewer_create_status}" != "200" ] && [ "${viewer_create_status}" != "201" ] && ! grep -qi "already" "${viewer_create_out}"; then
        cat "${viewer_create_out}" >&2
        die "Failed to create viewer user ${viewer_login}, HTTP ${viewer_create_status}"
      fi
      viewer_user_id="$(lookup_user_id "${viewer_login}" | head -n1)"
    fi
    [ -n "${viewer_user_id}" ] || die "Unable to resolve viewer user id for ${viewer_login}"

    local viewer_role_payload="${TMP_DIR}/viewer_role.json"
    local viewer_role_out="${TMP_DIR}/viewer_role.out"
    local viewer_role_status
    jq -n '{role: "Viewer"}' > "${viewer_role_payload}"
    viewer_role_status="$(
      curl -k -sS -o "${viewer_role_out}" -w '%{http_code}' \
        -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        -H 'Content-Type: application/json' \
        -X PATCH "${grafana_url}/api/org/users/${viewer_user_id}" \
        -d @"${viewer_role_payload}"
    )"
    if [ "${viewer_role_status}" != "200" ]; then
      cat "${viewer_role_out}" >&2
      die "Failed to set viewer role for ${viewer_login}, HTTP ${viewer_role_status}"
    fi

    add_team_member "${viewer_team_id}" "${viewer_user_id}" "${viewer_login}"
  fi

  local permission_payload="${TMP_DIR}/folder_permissions_viewer.json"
  jq -n \
    --argjson admin_team "${admin_team_id}" \
    --argjson viewer_team "${viewer_team_id}" \
    '{
      items: [
        {teamId: $admin_team, permission: 2},
        {teamId: $viewer_team, permission: 1}
      ]
    }' > "${permission_payload}"
  api_post "/api/folders/${viewer_folder_uid}/permissions" "${permission_payload}" >/dev/null

  local admin_permission_payload="${TMP_DIR}/folder_permissions_admin.json"
  jq -n \
    --argjson admin_team "${admin_team_id}" \
    '{
      items: [
        {teamId: $admin_team, permission: 2}
      ]
    }' > "${admin_permission_payload}"
  api_post "/api/folders/${admin_folder_uid}/permissions" "${admin_permission_payload}" >/dev/null

  resolve_dashboard_id() {
    local dashboard_uid="$1"
    api_get "/api/dashboards/uid/${dashboard_uid}" | jq -r '.dashboard.id // empty'
  }

  apply_dashboard_permissions() {
    local dashboard_uid="$1"
    local payload_file="$2"
    local dashboard_id
    dashboard_id="$(resolve_dashboard_id "${dashboard_uid}")"
    if [ -z "${dashboard_id}" ]; then
      echo "Skip dashboard ACL for ${dashboard_uid}: not found" >&2
      return
    fi
    api_post "/api/dashboards/id/${dashboard_id}/permissions" "${payload_file}" >/dev/null
  }

  local dashboard_permission_viewer_payload="${TMP_DIR}/dashboard_permissions_viewer.json"
  jq -n \
    --argjson admin_team "${admin_team_id}" \
    --argjson viewer_team "${viewer_team_id}" \
    '{
      items: [
        {teamId: $admin_team, permission: 2},
        {teamId: $viewer_team, permission: 1}
      ]
    }' > "${dashboard_permission_viewer_payload}"

  local dashboard_permission_admin_payload="${TMP_DIR}/dashboard_permissions_admin.json"
  jq -n \
    --argjson admin_team "${admin_team_id}" \
    '{
      items: [
        {teamId: $admin_team, permission: 2}
      ]
    }' > "${dashboard_permission_admin_payload}"

  local viewer_dashboard_uids=(
    iot-v1-admin-home
    iot-v1-admin-export
    iot-v1-plant-monitor
  )
  local admin_dashboard_uids=(
    iot-v1-admin-plant
    iot-v1-admin-point
    iot-v1-admin-device
    iot-v1-admin-metric
  )
  local dashboard_uid
  for dashboard_uid in "${viewer_dashboard_uids[@]}"; do
    apply_dashboard_permissions "${dashboard_uid}" "${dashboard_permission_viewer_payload}"
  done
  for dashboard_uid in "${admin_dashboard_uids[@]}"; do
    apply_dashboard_permissions "${dashboard_uid}" "${dashboard_permission_admin_payload}"
  done

  echo "Grafana access control ready (${STACK_ENV})"
}

emqx_login() {
  EMQX_API_BASE="${EMQX_API_BASE:-http://127.0.0.1:18083/api/v5}"

  local token
  token="$(curl -fsS -H 'Content-Type: application/json' -X POST "${EMQX_API_BASE}/login" -d "{\"username\":\"${EMQX_DASHBOARD_USER}\",\"password\":\"${EMQX_DASHBOARD_PASSWORD}\"}" | jq -r '.token')"
  [ -n "${token}" ] && [ "${token}" != "null" ] || die "Failed to get EMQX token"

  EMQX_AUTH=(-H "Authorization: Bearer ${token}" -H 'Content-Type: application/json')
}

configure_emqx_security() {
  local auth_id="password_based:built_in_database"

  if ! curl -fsS "${EMQX_AUTH[@]}" "${EMQX_API_BASE}/authentication/${auth_id}" >/dev/null 2>&1; then
    curl -fsS "${EMQX_AUTH[@]}" -X POST "${EMQX_API_BASE}/authentication" \
      -d '{"mechanism":"password_based","backend":"built_in_database","user_id_type":"username","enable":true,"password_hash_algorithm":{"name":"sha256","salt_position":"prefix"}}' >/dev/null
  fi

  local user_out="${TMP_DIR}/emqx_mqtt_user.out"
  local create_status
  create_status="$(curl -sS -o "${user_out}" -w '%{http_code}' "${EMQX_AUTH[@]}" -X POST "${EMQX_API_BASE}/authentication/${auth_id}/users" -d "{\"user_id\":\"${EMQX_MQTT_USERNAME}\",\"password\":\"${EMQX_MQTT_PASSWORD}\"}")"
  if [ "${create_status}" = "409" ]; then
    curl -fsS "${EMQX_AUTH[@]}" -X PUT "${EMQX_API_BASE}/authentication/${auth_id}/users/${EMQX_MQTT_USERNAME}" -d "{\"password\":\"${EMQX_MQTT_PASSWORD}\"}" >/dev/null
  elif [ "${create_status}" != "201" ] && [ "${create_status}" != "200" ]; then
    cat "${user_out}" >&2
    die "Create MQTT user failed: HTTP ${create_status}"
  fi

  local authz_settings
  authz_settings="$(curl -fsS "${EMQX_AUTH[@]}" "${EMQX_API_BASE}/authorization/settings")"
  local authz_cache_enable
  local authz_cache_excludes
  local authz_cache_max_size
  local authz_cache_ttl
  authz_cache_enable="$(printf '%s' "${authz_settings}" | jq '.cache.enable')"
  authz_cache_excludes="$(printf '%s' "${authz_settings}" | jq -c '.cache.excludes')"
  authz_cache_max_size="$(printf '%s' "${authz_settings}" | jq '.cache.max_size')"
  authz_cache_ttl="$(printf '%s' "${authz_settings}" | jq -r '.cache.ttl')"

  curl -fsS "${EMQX_AUTH[@]}" -X PUT "${EMQX_API_BASE}/authorization/settings" \
    -d '{"cache":{"enable":'"${authz_cache_enable}"',"excludes":'"${authz_cache_excludes}"',"max_size":'"${authz_cache_max_size}"',"ttl":"'"${authz_cache_ttl}"'"},"no_match":"deny","deny_action":"ignore"}' >/dev/null

  if ! curl -fsS "${EMQX_AUTH[@]}" "${EMQX_API_BASE}/authorization/sources/built_in_database" >/dev/null 2>&1; then
    curl -fsS "${EMQX_AUTH[@]}" -X POST "${EMQX_API_BASE}/authorization/sources" -d '{"type":"built_in_database","enable":true}' >/dev/null
  fi

  curl -fsS "${EMQX_AUTH[@]}" -X POST "${EMQX_API_BASE}/authorization/sources/built_in_database/move" -d '{"position":"front"}' >/dev/null || true

  if curl -fsS "${EMQX_AUTH[@]}" "${EMQX_API_BASE}/authorization/sources/file" >/dev/null 2>&1; then
    local file_source
    local file_rules
    file_source="$(curl -fsS "${EMQX_AUTH[@]}" "${EMQX_API_BASE}/authorization/sources/file")"
    file_rules="$(printf '%s' "${file_source}" | jq -r '.rules')"
    curl -fsS "${EMQX_AUTH[@]}" -X PUT "${EMQX_API_BASE}/authorization/sources/file" -d '{"type":"file","enable":false,"rules":'"$(printf '%s' "${file_rules}" | jq -Rs .)"'}' >/dev/null || true
  fi

  curl -fsS "${EMQX_AUTH[@]}" -X PUT "${EMQX_API_BASE}/authorization/sources/built_in_database/rules/users/${EMQX_MQTT_USERNAME}" \
    -d '{"username":"'"${EMQX_MQTT_USERNAME}"'","rules":[{"permission":"allow","action":"publish","topic":"water/v1/+/+/+/telemetry"},{"permission":"allow","action":"subscribe","topic":"water/v1/+/+/+/cmd/+"},{"permission":"deny","action":"all","topic":"#"}]}' >/dev/null

  echo "EMQX security ready (${STACK_ENV})"
}

post_or_allow_exists() {
  local endpoint="$1"
  local payload_file="$2"
  local output_file="$3"

  local status
  status="$(curl -sS -o "${output_file}" -w '%{http_code}' "${EMQX_AUTH[@]}" -X POST "${EMQX_API_BASE}/${endpoint}" -d @"${payload_file}")"
  if [ "${status}" = "200" ] || [ "${status}" = "201" ]; then
    return 0
  fi

  if [ "${status}" = "400" ] && grep -q 'ALREADY_EXISTS' "${output_file}"; then
    return 0
  fi

  cat "${output_file}" >&2
  die "Create ${endpoint} failed: HTTP ${status}"
}

configure_emqx_direct_ingest() {
  local connector_name="ts_conn_water_v1"
  local connector_id="timescale:${connector_name}"
  local action_name="ts_ingest_telemetry_water_v1"
  local action_id="timescale:${action_name}"
  local rule_id="rule_water_v1_telemetry"

  local connector_json="${TMP_DIR}/connector.json"
  local action_json="${TMP_DIR}/action.json"
  local rule_json="${TMP_DIR}/rule.json"

  cat > "${connector_json}" <<EOF_CONNECTOR
{
  "type": "timescale",
  "name": "${connector_name}",
  "enable": true,
  "server": "timescaledb:5432",
  "database": "${POSTGRES_DB}",
  "username": "${EMQX_TS_DB_USER}",
  "password": "${EMQX_TS_DB_PASSWORD}",
  "ssl": {
    "enable": ${PG_SSL_ENABLE:-true},
    "verify": "${PG_SSL_VERIFY:-verify_none}"
  }
}
EOF_CONNECTOR

  cat > "${action_json}" <<EOF_ACTION
{
  "type": "timescale",
  "name": "${action_name}",
  "enable": true,
  "connector": "${connector_name}",
  "parameters": {
    "sql": "SELECT ingest_telemetry(\${topic}, \${payload}::jsonb, \${clientid}, \${qos});"
  },
  "resource_opts": {
    "batch_size": 1,
    "batch_time": "50ms",
    "query_mode": "sync"
  }
}
EOF_ACTION

  cat > "${rule_json}" <<EOF_RULE
{
  "id": "${rule_id}",
  "name": "water_v1_telemetry_to_timescale",
  "enable": true,
  "sql": "SELECT * FROM \"water/v1/+/+/+/telemetry\"",
  "actions": [
    "${action_id}"
  ],
  "description": "Route water/v1 telemetry to ingest_telemetry()"
}
EOF_RULE

  curl -sS "${EMQX_AUTH[@]}" -X DELETE "${EMQX_API_BASE}/rules/${rule_id}" >/dev/null || true
  curl -sS "${EMQX_AUTH[@]}" -X DELETE "${EMQX_API_BASE}/actions/${action_id}" >/dev/null || true
  curl -sS "${EMQX_AUTH[@]}" -X DELETE "${EMQX_API_BASE}/connectors/${connector_id}" >/dev/null || true

  post_or_allow_exists "connectors" "${connector_json}" "${TMP_DIR}/connectors.out"
  post_or_allow_exists "actions" "${action_json}" "${TMP_DIR}/actions.out"
  post_or_allow_exists "rules" "${rule_json}" "${TMP_DIR}/rules.out"

  echo "EMQX direct ingest ready (${STACK_ENV})"
}

run_configure() {
  parse_env_only_args "$@"
  require_cmd curl
  require_cmd jq
  require_cmd jsonnet
  "${SCRIPT_DIR}/generate_admin_dashboards.sh" --check || "${SCRIPT_DIR}/generate_admin_dashboards.sh"
  load_env "${STACK_ENV_ARG}"

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT

  reconcile_db_schema
  configure_runtime_db_roles
  configure_grafana_db_roles
  compose_stack restart postgrest >/dev/null
  echo "PostgREST schema cache refreshed (${STACK_ENV})"
  configure_grafana_nav_panel
  configure_grafana_access_control
  emqx_login
  configure_emqx_security
  configure_emqx_direct_ingest

  echo "Runtime configuration completed for ${STACK_ENV}"
}

tls_parse_args() {
  STACK_ENV_ARG=""
  DOMAIN_ARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --env)
        [ $# -ge 2 ] || die "--env requires a value"
        STACK_ENV_ARG="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [ -z "${DOMAIN_ARG}" ]; then
          DOMAIN_ARG="$1"
          shift
        else
          die "Unexpected argument: $1"
        fi
        ;;
    esac
  done

  [ -n "${STACK_ENV_ARG}" ] || die "Missing --env <prod|test>"
}

tls_resolve_domain() {
  if [ -n "${DOMAIN_ARG}" ]; then
    printf '%s\n' "${DOMAIN_ARG}"
    return
  fi
  if [ -n "${TLS_DOMAIN:-}" ]; then
    printf '%s\n' "${TLS_DOMAIN}"
    return
  fi
  if [ -n "${RENEWED_LINEAGE:-}" ]; then
    basename "${RENEWED_LINEAGE}"
    return
  fi
  die "Missing domain"
}

tls_sync_certs() {
  local domain="$1"
  local le_dir="/etc/letsencrypt/live/${domain}"
  [ -f "${le_dir}/fullchain.pem" ] || die "Missing certificate: ${le_dir}/fullchain.pem"
  [ -f "${le_dir}/privkey.pem" ] || die "Missing certificate: ${le_dir}/privkey.pem"

  install -d -m 755 "${STACK_DIR}/emqx/certs" "${STACK_DIR}/grafana/certs" "${STACK_DIR}/postgres/certs"

  install -m 644 "${le_dir}/fullchain.pem" "${STACK_DIR}/emqx/certs/server-cert.pem"
  install -m 640 "${le_dir}/privkey.pem" "${STACK_DIR}/emqx/certs/server-key.pem"
  chown root:1000 "${STACK_DIR}/emqx/certs/server-key.pem"

  install -m 644 "${le_dir}/fullchain.pem" "${STACK_DIR}/emqx/certs/cert.pem"
  install -m 640 "${le_dir}/privkey.pem" "${STACK_DIR}/emqx/certs/key.pem"
  install -m 644 "${le_dir}/fullchain.pem" "${STACK_DIR}/emqx/certs/cacert.pem"
  chown root:1000 "${STACK_DIR}/emqx/certs/key.pem"

  install -m 644 "${le_dir}/fullchain.pem" "${STACK_DIR}/grafana/certs/fullchain.pem"
  install -m 640 "${le_dir}/privkey.pem" "${STACK_DIR}/grafana/certs/privkey.pem"
  chown root:0 "${STACK_DIR}/grafana/certs/privkey.pem"

  install -m 644 "${le_dir}/fullchain.pem" "${STACK_DIR}/postgres/certs/server.crt"
  install -m 640 "${le_dir}/privkey.pem" "${STACK_DIR}/postgres/certs/server.key"
  chown root:70 "${STACK_DIR}/postgres/certs/server.key"

  echo "TLS certs synced for ${domain} (${STACK_ENV})"
}

tls_restart_services() {
  compose_stack restart timescaledb emqx grafana
}

run_tls_issue() {
  tls_parse_args "$@"
  load_env "${STACK_ENV_ARG}"
  require_cmd certbot

  local domain
  domain="$(tls_resolve_domain)"
  local email="${TLS_CERT_EMAIL:-}"

  if [ -n "${email}" ]; then
    certbot certonly --standalone --non-interactive --agree-tos --email "${email}" --preferred-challenges http -d "${domain}"
  else
    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email --preferred-challenges http -d "${domain}"
  fi

  tls_sync_certs "${domain}"
  tls_restart_services
  echo "TLS issued and deployed for ${domain} (${STACK_ENV})"
}

run_tls_deploy() {
  tls_parse_args "$@"
  load_env "${STACK_ENV_ARG}"

  local domain
  domain="$(tls_resolve_domain)"
  tls_sync_certs "${domain}"
  tls_restart_services
  echo "TLS deployed for ${domain} (${STACK_ENV})"
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 1
fi

COMMAND="$1"
shift

case "${COMMAND}" in
  up)
    run_up "$@"
    ;;
  configure)
    run_configure "$@"
    ;;
  release)
    parse_env_fresh_args "$@"
    if [ "${FRESH}" = "true" ]; then
      run_up --env "${STACK_ENV_ARG}" --fresh
    else
      run_up --env "${STACK_ENV_ARG}"
    fi
    run_configure --env "${STACK_ENV_ARG}"
    echo "Release completed for ${STACK_ENV_ARG}"
    ;;
  tls)
    [ $# -ge 1 ] || { usage >&2; exit 1; }
    TLS_SUBCOMMAND="$1"
    shift
    case "${TLS_SUBCOMMAND}" in
      issue|deploy)
        run_tls_${TLS_SUBCOMMAND} "$@"
        ;;
      *)
        echo "Unknown tls subcommand: ${TLS_SUBCOMMAND}" >&2
        usage >&2
        exit 1
        ;;
    esac
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    usage >&2
    exit 1
    ;;
esac
