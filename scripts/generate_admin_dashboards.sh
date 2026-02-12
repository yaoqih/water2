#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSONNET_FILE="${ROOT_DIR}/grafana/provisioning/dashboards/jsonnet/admin.main.jsonnet"
MONITOR_JSONNET_FILE="${ROOT_DIR}/grafana/provisioning/dashboards/jsonnet/plant-monitor.main.jsonnet"
OUT_DIR="${ROOT_DIR}/grafana/provisioning/dashboards/v1"
MONITOR_OUT_FILE="${OUT_DIR}/iot-v1-plant-monitor.json"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

JSONNET_BIN=""
if command -v jsonnet >/dev/null 2>&1; then
  JSONNET_BIN="jsonnet"
elif command -v go-jsonnet >/dev/null 2>&1; then
  JSONNET_BIN="go-jsonnet"
else
  echo "missing required command: jsonnet (or go-jsonnet)" >&2
  exit 1
fi

need_cmd jq

tmp_json="$(mktemp)"
trap 'rm -f "$tmp_json"' EXIT

"$JSONNET_BIN" "$JSONNET_FILE" > "$tmp_json"

render_one() {
  local key="$1"
  local name="$2"
  local out_file="${OUT_DIR}/iot-v1-admin-${name}.json"

  jq -e --arg key "$key" '.[$key]' "$tmp_json" > /dev/null
  jq --arg key "$key" '.[$key]' "$tmp_json" > "$out_file"
  echo "generated: ${out_file}"
}

validate_generated() {
  local failed=0
  for file in \
    "${OUT_DIR}/iot-v1-admin-plant.json" \
    "${OUT_DIR}/iot-v1-admin-point.json" \
    "${OUT_DIR}/iot-v1-admin-device.json" \
    "${OUT_DIR}/iot-v1-admin-metric.json" \
    "${MONITOR_OUT_FILE}"; do
    if ! jq -e . "$file" > /dev/null; then
      echo "invalid json: ${file}" >&2
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
}

if [[ "${1:-}" == "--check" ]]; then
  failed=0
  new_file="$(mktemp)"
  new_monitor_file="$(mktemp)"
  trap 'rm -f "$tmp_json" "$new_file" "$new_monitor_file"' EXIT
  for pair in "plant:plant" "point:point" "device:device" "metric:metric"; do
    key="${pair%%:*}"
    name="${pair##*:}"
    out_file="${OUT_DIR}/iot-v1-admin-${name}.json"
    jq --arg key "$key" '.[$key]' "$tmp_json" > "$new_file"
    if ! cmp -s "$new_file" "$out_file"; then
      echo "outdated: ${out_file}" >&2
      failed=1
    fi
  done

  "$JSONNET_BIN" "$MONITOR_JSONNET_FILE" > "$new_monitor_file"
  if ! cmp -s "$new_monitor_file" "${MONITOR_OUT_FILE}"; then
    echo "outdated: ${MONITOR_OUT_FILE}" >&2
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
  exit 0
fi

render_one plant plant
render_one point point
render_one device device
render_one metric metric
tmp_monitor_file="$(mktemp)"
trap 'rm -f "$tmp_json" "$tmp_monitor_file"' EXIT
"$JSONNET_BIN" "$MONITOR_JSONNET_FILE" > "${tmp_monitor_file}"
mv "${tmp_monitor_file}" "${MONITOR_OUT_FILE}"
echo "generated: ${MONITOR_OUT_FILE}"
validate_generated
