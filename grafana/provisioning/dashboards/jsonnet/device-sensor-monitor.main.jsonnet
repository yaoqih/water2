local nav = import 'nav.libsonnet';
local readDatasource = 'TimescaleDB-RO';

local commonAnnotations = {
  list: [
    {
      builtIn: 1,
      datasource: { type: 'grafana', uid: '-- Grafana --' },
      enable: true,
      hide: true,
      iconColor: 'rgba(0, 211, 255, 1)',
      name: 'Annotations & Alerts',
      type: 'dashboard',
    },
  ],
};

local sqlMeta(limit=500) = {
  columns: [{ parameters: [], type: 'function' }],
  groupBy: [{ property: { type: 'string' }, type: 'groupBy' }],
  limit: limit,
};

local queryVar(name, label, query, hide=0, multi=false, includeAll=false, current={ selected: false, text: '', value: '' }) = {
  name: name,
  type: 'query',
  datasource: readDatasource,
  label: label,
  query: query,
  definition: query,
  refresh: 1,
  hide: hide,
  includeAll: includeAll,
  multi: multi,
  sort: 1,
  skipUrlSync: false,
  current: current,
  options: [],
  regex: '',
};

local tableTarget(refId, rawSql, limit=500) = {
  refId: refId,
  datasource: readDatasource,
  editorMode: 'code',
  format: 'table',
  rawQuery: true,
  rawSql: rawSql,
  sql: sqlMeta(limit),
};

local timeSeriesTarget(refId, rawSql, limit=5000) = {
  refId: refId,
  datasource: readDatasource,
  editorMode: 'code',
  format: 'time_series',
  rawQuery: true,
  rawSql: rawSql,
  sql: sqlMeta(limit),
};

local plantQuery = |||
  SELECT p.plant_id AS __value,
         COALESCE(NULLIF(btrim(p.plant_name), ''), p.plant_id) AS __text
  FROM plant p
  ORDER BY __text;
|||;

local pointQuery = |||
  SELECT pt.point_id AS __value,
         CASE
           WHEN NULLIF(btrim(COALESCE(pt.point_name, '')), '') IS NULL THEN pt.point_id || ' [' || pt.point_type || ']'
           ELSE pt.point_name || ' [' || pt.point_type || ']'
         END AS __text
  FROM point pt
  WHERE pt.plant_id = ${plant_id:sqlstring}
  ORDER BY __text;
|||;

local deviceQuery = |||
  SELECT d.device_id AS __value,
         CASE
           WHEN d.enabled IS TRUE THEN d.device_id
           ELSE d.device_id || ' [disabled]'
         END AS __text
  FROM device d
  WHERE d.point_id = ${point_id:sqlstring}
  ORDER BY d.device_id;
|||;

local metricCardsQuery = |||
  WITH metrics AS (
    SELECT DISTINCT
      v.metric,
      COALESCE(NULLIF(btrim(v.display_name), ''), v.metric) AS display_name,
      NULLIF(btrim(COALESCE(v.unit, '')), '') AS unit
    FROM admin_api.v_device_metric_latest v
    WHERE v.plant_id = ${plant_id:sqlstring}
      AND v.point_id = ${point_id:sqlstring}
      AND v.device_id = ${device_id:sqlstring}
      AND v.visible IS DISTINCT FROM false
  ), named AS (
    SELECT
      metric,
      CASE
        WHEN unit IS NULL THEN display_name
        ELSE display_name || ' (' || unit || ')'
      END AS metric_text
    FROM metrics
  ), dedup AS (
    SELECT
      metric,
      metric_text,
      COUNT(*) OVER (PARTITION BY metric_text) AS text_dup_count
    FROM named
  )
  SELECT metric AS __value,
         CASE
           WHEN text_dup_count > 1 THEN metric_text || ' [' || metric || ']'
           ELSE metric_text
         END AS __text
  FROM dedup
  ORDER BY metric;
|||;

local overviewQuery = |||
  WITH latest AS (
    SELECT *
    FROM admin_api.v_device_metric_latest v
    WHERE v.plant_id = ${plant_id:sqlstring}
      AND v.point_id = ${point_id:sqlstring}
      AND v.device_id = ${device_id:sqlstring}
      AND v.visible IS DISTINCT FROM false
  )
  SELECT
    COALESCE(max(plant_name), ${plant_id:sqlstring}) AS "厂站",
    COALESCE(max(point_name), ${point_id:sqlstring}) AS "点位",
    COALESCE(max(point_type), '') AS "点位类型",
    ${device_id:sqlstring} AS "设备",
    max(report_interval_sec) AS "上报周期(s)",
    COALESCE(max(align_mode), '') AS "对齐方式",
    COALESCE(bool_and(COALESCE(enabled, TRUE)), TRUE) AS "启用",
    max(last_seen_at) AS "设备最近在线",
    max(ingest_ts) AS "最近指标时间",
    count(*) AS "指标数",
    sum(CASE WHEN is_fresh THEN 1 ELSE 0 END) AS "新鲜指标数",
    string_agg(DISTINCT topic, ', ' ORDER BY topic) FILTER (WHERE COALESCE(topic, '') <> '') AS "Topic"
  FROM latest;
|||;

local latestValueQuery = |||
  SELECT round(v.value_num::numeric, 3) AS value
  FROM admin_api.v_device_metric_latest v
  WHERE v.plant_id = ${plant_id:sqlstring}
    AND v.point_id = ${point_id:sqlstring}
    AND v.device_id = ${device_id:sqlstring}
    AND v.metric = ${metric_cards:sqlstring}
    AND v.visible IS DISTINCT FROM false
  LIMIT 1;
|||;

local updateAgeQuery = |||
  WITH latest AS (
    SELECT v.freshness_sec
    FROM admin_api.v_device_metric_latest v
    WHERE v.plant_id = ${plant_id:sqlstring}
      AND v.point_id = ${point_id:sqlstring}
      AND v.device_id = ${device_id:sqlstring}
      AND v.metric = ${metric_cards:sqlstring}
      AND v.visible IS DISTINCT FROM false
    LIMIT 1
  )
  SELECT freshness_sec AS value
  FROM latest;
|||;

local seriesQuery = |||
  SELECT
    v.ingest_ts AS "time",
    v.value_num AS "value"
  FROM admin_api.v_device_metric_series v
  WHERE v.plant_id = ${plant_id:sqlstring}
    AND v.point_id = ${point_id:sqlstring}
    AND v.device_id = ${device_id:sqlstring}
    AND v.metric = ${metric_cards:sqlstring}
    AND v.visible IS DISTINCT FROM false
    AND $__timeFilter(v.ingest_ts)
  ORDER BY v.ingest_ts;
|||;

{
  annotations: commonAnnotations,
  editable: true,
  id: null,
  panels: [
    {
      id: 1,
      title: '导航',
      type: 'text',
      gridPos: { h: 2, w: 24, x: 0, y: 0 },
      libraryPanel: {
        uid: 'lib_iot_view_nav',
        name: 'IoT Viewer Navigation',
      },
      options: {
        mode: 'markdown',
        content: nav.viewer_content,
      },
    },
    {
      id: 2,
      title: '设备上下文',
      type: 'text',
      gridPos: { h: 2, w: 24, x: 0, y: 2 },
      options: {
        mode: 'markdown',
        content: '> **通用设备监控**：${plant_id:text} · ${point_id:text} · `${device_id}`\n\n每个指标占一行：左侧当前值，中间更新距今，右侧趋势图；时间范围由右上角时间选择器控制。',
      },
    },
    {
      id: 3,
      title: '设备概览',
      type: 'table',
      gridPos: { h: 5, w: 24, x: 0, y: 4 },
      datasource: readDatasource,
      targets: [
        tableTarget('A', overviewQuery, 50),
      ],
      options: {
        footer: { show: false, reducer: ['sum'] },
        showHeader: true,
      },
      fieldConfig: {
        defaults: {
          custom: {
            align: 'left',
            cellOptions: { type: 'auto' },
            inspect: false,
          },
        },
        overrides: [],
      },
    },
    {
      id: 10,
      title: '${metric_cards:text}',
      type: 'stat',
      gridPos: { h: 6, w: 5, x: 0, y: 9 },
      datasource: readDatasource,
      repeat: 'metric_cards',
      repeatDirection: 'v',
      targets: [
        tableTarget('A', latestValueQuery, 20),
      ],
      options: {
        colorMode: 'none',
        graphMode: 'none',
        justifyMode: 'auto',
        orientation: 'auto',
        reduceOptions: {
          calcs: ['lastNotNull'],
          fields: '/^value$/',
          values: false,
        },
        textMode: 'value',
      },
      fieldConfig: {
        defaults: {
          decimals: 3,
          noValue: '暂无',
          thresholds: {
            mode: 'absolute',
            steps: [
              { color: '#73BF69', value: null },
            ],
          },
        },
        overrides: [],
      },
    },
    {
      id: 15,
      title: '更新距今',
      type: 'stat',
      gridPos: { h: 6, w: 4, x: 5, y: 9 },
      datasource: readDatasource,
      repeat: 'metric_cards',
      repeatDirection: 'v',
      targets: [
        tableTarget('A', updateAgeQuery, 20),
      ],
      options: {
        colorMode: 'value',
        graphMode: 'none',
        justifyMode: 'center',
        orientation: 'auto',
        reduceOptions: {
          calcs: ['lastNotNull'],
          fields: '/^value$/',
          values: false,
        },
        textMode: 'value',
      },
      fieldConfig: {
        defaults: {
          decimals: 0,
          noValue: '暂无更新',
          unit: 's',
          thresholds: {
            mode: 'absolute',
            steps: [
              { color: '#73BF69', value: null },
              { color: '#F2CC0C', value: 60 },
              { color: '#E24D42', value: 120 },
            ],
          },
        },
        overrides: [],
      },
    },
    {
      id: 20,
      title: '${metric_cards:text} 趋势',
      type: 'timeseries',
      gridPos: { h: 6, w: 15, x: 9, y: 9 },
      datasource: readDatasource,
      repeat: 'metric_cards',
      repeatDirection: 'v',
      targets: [
        timeSeriesTarget('A', seriesQuery, 5000),
      ],
      options: {
        legend: {
          calcs: ['lastNotNull', 'min', 'max'],
          displayMode: 'list',
          placement: 'right',
        },
        tooltip: {
          mode: 'single',
          sort: 'none',
        },
      },
      fieldConfig: {
        defaults: {
          color: { mode: 'palette-classic' },
          custom: {
            axisBorderShow: false,
            axisCenteredZero: false,
            axisColorMode: 'text',
            axisLabel: '',
            axisPlacement: 'auto',
            drawStyle: 'line',
            fillOpacity: 8,
            gradientMode: 'none',
            hideFrom: {
              legend: false,
              tooltip: false,
              viz: false,
            },
            lineInterpolation: 'smooth',
            lineWidth: 2,
            pointSize: 2,
            scaleDistribution: { type: 'linear' },
            showPoints: 'never',
            spanNulls: true,
            stacking: {
              group: 'A',
              mode: 'none',
            },
            thresholdsStyle: { mode: 'off' },
          },
          decimals: 3,
          noValue: '暂无',
        },
        overrides: [],
      },
    },
  ],
  refresh: '30s',
  schemaVersion: 39,
  tags: ['iot', 'viewer', 'device', 'sensor'],
  templating: {
    list: [
      queryVar('plant_id', '厂站', plantQuery),
      queryVar('point_id', '点位', pointQuery),
      queryVar('device_id', '设备', deviceQuery),
      queryVar(
        'metric_cards',
        '指标',
        metricCardsQuery,
        0,
        true,
        true,
        { selected: true, text: 'All', value: '$__all' }
      ),
    ],
  },
  time: {
    from: 'now-6h',
    to: 'now',
  },
  timepicker: {},
  timezone: 'browser',
  title: 'IoT V1 · Device Sensor Monitor',
  uid: 'iot-v1-device-sensor-monitor',
  version: 1,
}
