local readDatasource = 'TimescaleDB-RO';
local writeDatasource = 'TimescaleDB-Admin';
local nav = import 'nav.libsonnet';

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

local refreshBlock = |||
    let refreshed = false;
    try {
      if (typeof context.grafana.refresh === 'function') {
        context.grafana.refresh();
        refreshed = true;
      }
    } catch (e) {}
    
    setTimeout(() => {
      try {
        if (context.grafana.locationService && typeof context.grafana.locationService.reload === 'function') {
          context.grafana.locationService.reload();
        } else if (!refreshed && typeof window !== 'undefined' && window.location) {
          window.location.reload();
        }
      } catch (e) {}
    }, 100);
|||;

local deleteRefreshBlock = |||
    try {
      if (typeof context.grafana.refresh === 'function') {
        context.grafana.refresh();
      }
    } catch (e) {}
|||;

local initialCodeTemplate = |||
  const autoId = String('${<<DELETE_VAR>>}' ?? '').trim();
  if (!autoId) return;
  const guardStore = (typeof window !== 'undefined')
    ? (window.__iotAdminDeleteGuards = window.__iotAdminDeleteGuards || {})
    : null;
  const guardKey = '<<DELETE_VAR>>:' + autoId;
  if (guardStore && guardStore[guardKey]) return;
  if (guardStore) {
    guardStore[guardKey] = true;
  }
  const releaseGuard = () => {
    if (guardStore) {
      delete guardStore[guardKey];
    }
  };
  return (async () => {
    try {
      if (!confirm(<<DELETE_CONFIRM>>)) {
        context.grafana.locationService.partial({'var-<<DELETE_VAR>>': '', 'var-<<EDIT_VAR>>': ''}, true);
        return;
      }
      context.grafana.locationService.partial({'var-<<DELETE_VAR>>': ''}, true);
      const dsName = context.panel.options?.update?.datasource || 'TimescaleDB-Admin';
      const dsInfo = await context.grafana.backendService.get('/api/datasources/name/' + encodeURIComponent(dsName));
      const uid = dsInfo?.uid;
      if (!uid) throw new Error('未找到数据源: ' + dsName);
      const rawSql = <<DELETE_RAW_SQL>>;
      const body = {
        queries: [{
          refId: 'A',
          datasource: { uid },
          editorMode: 'code',
          format: 'table',
          rawQuery: true,
          rawSql,
          sql: { columns: [{ parameters: [], type: 'function' }], groupBy: [{ property: { type: 'string' }, type: 'groupBy' }], limit: 50 }
        }],
        from: 'now-5m',
        to: 'now'
      };
      const queryResp = await context.grafana.backendService.post('/api/ds/query', body);
      const result = queryResp?.results?.A;
      if (result?.error) throw new Error(result.error);
      const frame = result?.frames?.[0];
      const row = {};
      if (frame?.schema?.fields && Array.isArray(frame?.data?.values)) {
        frame.schema.fields.forEach((f, idx) => { row[f.name] = frame.data.values[idx]?.[0]; });
      }
      const objectId = String(row.<<DELETE_OBJECT_FIELD>> ?? autoId).trim();
      const detail = <<DELETE_DETAIL_EXPR>>;
      const nowIso = new Date().toISOString();
      context.grafana.notifySuccess(['删除成功', '🗑 已删除<<OBJECT_CN>> ' + objectId + '，' + detail]);
      context.grafana.locationService.partial({'var-<<DELETE_VAR>>': '', 'var-<<EDIT_VAR>>': '', 'var-<<LAST_VAR>>': '🗑 已删除<<OBJECT_CN>> ' + objectId + '，' + detail, 'var-<<LAST_TS_VAR>>': nowIso}, true);
    <<DELETE_REFRESH_BLOCK>>
    } catch (error) {
      context.grafana.locationService.partial({'var-<<DELETE_VAR>>': '', 'var-<<EDIT_VAR>>': ''}, true);
      const msg = error?.message || error?.data?.message || error?.data?.results?.A?.error || error?.statusText || (typeof error === 'string' ? error : '');
      context.grafana.notifyError(['删除失败', msg || '请检查关联关系或输入']);
    } finally {
      releaseGuard();
    }
  })();
|||;

local updateCodeTemplate = |||
  const ok = context.panel.response && context.panel.response.state === 'Done';
  if (ok) {
    const get = (id) => context.panel.elements.find((e) => e.id === id)?.value;
    const objectId = String(get('<<OBJECT_ID_FIELD>>') ?? '').trim();
    const nowIso = new Date().toISOString();
    const msg = '💾 已保存<<OBJECT_CN>> ' + (objectId || '-');
    context.grafana.notifySuccess(['成功', msg]);
    context.grafana.locationService.partial({
      'var-<<LAST_VAR>>': msg,
      'var-<<LAST_TS_VAR>>': nowIso,
      'var-<<DELETE_VAR>>': '',
      'var-<<EDIT_VAR>>': objectId || ''
    }, true);
  
  <<REFRESH_BLOCK>>
  } else {
    context.grafana.notifyError(['失败', '请检查输入']);
  }
|||;

local renderTemplate(template, replacements) =
  std.foldl(
    function(acc, key)
      std.strReplace(acc, '<<' + key + '>>', replacements[key]),
    std.objectFields(replacements),
    template
  );

local sqlMeta(limit=500) = {
  columns: [{ parameters: [], type: 'function' }],
  groupBy: [{ property: { type: 'string' }, type: 'groupBy' }],
  limit: limit,
};

local queryTarget(refId, rawSql, limit=500) = {
  refId: refId,
  datasource: readDatasource,
  editorMode: 'code',
  format: 'table',
  rawQuery: true,
  rawSql: rawSql,
  sql: sqlMeta(limit),
};

local queryVar(name, query) = {
  name: name,
  type: 'query',
  datasource: readDatasource,
  query: query,
  definition: query,
  refresh: 1,
  hide: 2,
  includeAll: false,
  multi: false,
  sort: 1,
  skipUrlSync: false,
  current: { selected: false, text: '', value: '' },
  options: [],
  regex: '',
};

local textboxVar(name) = {
  current: { selected: false, text: '', value: '' },
  hide: 2,
  label: '',
  name: name,
  options: [{ selected: true, text: '', value: '' }],
  query: '',
  skipUrlSync: false,
  type: 'textbox',
};

local queryField(refId, value) = { refId: refId, value: value, label: refId + ':' + value };

local selectQueryElement(elementId, title, fieldName, sourceRef, queryValue, value, syncFromQuery=true) =
  {
    id: elementId,
    title: title,
    type: 'select',
    options: [],
    optionsSource: 'Query',
    queryOptions: { source: sourceRef, label: 'label', value: 'value' },
    fieldName: fieldName,
    value: value,
  } + if syncFromQuery then { queryField: queryField('A', queryValue) } else {};

local selectStaticElement(elementId, title, fieldName, options, value, queryValue) = {
  id: elementId,
  title: title,
  type: 'select',
  options: options,
  fieldName: fieldName,
  value: value,
  queryField: queryField('A', queryValue),
};

local simpleElement(elementId, title, elementType, fieldName, value, queryValue) = {
  id: elementId,
  title: title,
  type: elementType,
  fieldName: fieldName,
  value: value,
  queryField: queryField('A', queryValue),
};

local navPanel = {
  id: 1,
  title: '导航',
  type: 'text',
  gridPos: { h: 2, w: 24, x: 0, y: 0 },
  libraryPanel: {
    uid: 'lib_iot_admin_nav',
    name: 'IoT Admin Navigation',
  },
  options: {
    mode: 'markdown',
    content: if std.objectHas(nav, 'admin_content') then nav.admin_content else nav.content,
  },
};

local statusPanel(spec) = {
  id: spec.status_panel_id,
  title: '操作状态',
  type: 'text',
  gridPos: { h: 2, w: 24, x: 0, y: 2 },
  options: {
    mode: 'markdown',
    content: '> **操作状态（' + spec.status_cn + '）**：${' + spec.last_var + '}  `${' + spec.last_ts_var + '}`',
  },
};

local tablePanel(spec) =
  local encodedRowId = '${__data.fields.' + spec.table_id_field + ':percentencode}';
  local editUrl = '/d/' + spec.uid + '?var-' + spec.edit_var + '=' + encodedRowId;
  local deleteUrl =
    '/d/' + spec.uid + '?var-' + spec.edit_var + '=' + encodedRowId +
    '&var-' + spec.delete_var + '=' + encodedRowId;
  {
    id: 3,
    title: spec.table_title,
    type: 'table',
    gridPos: { h: spec.table_h, w: 24, x: 0, y: 4 },
    datasource: readDatasource,
    targets: [
      {
        refId: 'A',
        format: 'table',
        rawQuery: true,
        rawSql: spec.table_sql,
      },
    ],
    fieldConfig: {
      defaults: {},
      overrides: [
        {
          matcher: { id: 'byName', options: 'edit' },
          properties: [
            {
              id: 'links',
              value: [{ title: '编辑', url: editUrl, targetBlank: false }],
            },
            { id: 'displayName', value: '编辑' },
            { id: 'custom.width', value: 90 },
          ],
        },
        {
          matcher: { id: 'byName', options: 'delete' },
          properties: [
            {
              id: 'links',
              value: [{ title: '删除', url: deleteUrl, targetBlank: false }],
            },
            { id: 'displayName', value: '删除' },
            { id: 'custom.width', value: 90 },
          ],
        },
      ],
    },
  };

local formPanel(spec) =
  local formTargets =
    [queryTarget('A', spec.form_query_sql), queryTarget('B', spec.form_pick_sql)] +
    std.map(function(target) queryTarget(target.refId, target.rawSql), spec.extra_targets);
  local elementValueChanged = renderTemplate(
    |||
  if (context.element.id === '<<PICK_ID>>') {
    const v = String(context.element.value ?? '').trim();
    context.grafana.locationService.partial({'var-<<EDIT_VAR>>': v}, true);
    const syncObj = {};
    syncObj['<<PICK_ID>>'] = v;
    context.panel.setFormValue(syncObj);
    if (!v) {
      context.panel.setFormValue(<<RESET_FORM_VALUE>>);
    }
    const focusPrimaryField = () => {
      if (typeof document === 'undefined') return;
      const selectors = [
        'input[name="<<OBJECT_ID_FIELD>>"]',
        'textarea[name="<<OBJECT_ID_FIELD>>"]',
        'input[id="<<OBJECT_ID_FIELD>>"]',
        '[aria-label="<<OBJECT_ID_FIELD>>"]',
        '[data-testid*="<<OBJECT_ID_FIELD>>"] input',
      ];
      for (const selector of selectors) {
        const el = document.querySelector(selector);
        if (el && typeof el.focus === 'function') {
          el.focus();
          if (typeof el.select === 'function') {
            el.select();
          }
          break;
        }
      }
    };
    setTimeout(focusPrimaryField, 0);
    setTimeout(focusPrimaryField, 120);
  }
|||,
    {
      PICK_ID: spec.pick_id,
      EDIT_VAR: spec.edit_var,
      RESET_FORM_VALUE: spec.reset_form_value,
      OBJECT_ID_FIELD: spec.object_id_field,
    }
  );
  local initialCode = renderTemplate(
    initialCodeTemplate,
    {
      DELETE_VAR: spec.delete_var,
      EDIT_VAR: spec.edit_var,
      LAST_VAR: spec.last_var,
      LAST_TS_VAR: spec.last_ts_var,
      OBJECT_CN: spec.object_cn,
      DELETE_CONFIRM: spec.delete_confirm,
      DELETE_RAW_SQL: spec.delete_raw_sql,
      DELETE_OBJECT_FIELD: spec.delete_object_field,
      DELETE_DETAIL_EXPR: spec.delete_detail_expr,
      DELETE_REFRESH_BLOCK: deleteRefreshBlock,
    }
  );
  local updateCode = renderTemplate(
    updateCodeTemplate,
    {
      OBJECT_ID_FIELD: spec.object_id_field,
      OBJECT_CN: spec.object_cn,
      LAST_VAR: spec.last_var,
      LAST_TS_VAR: spec.last_ts_var,
      DELETE_VAR: spec.delete_var,
      EDIT_VAR: spec.edit_var,
      REFRESH_BLOCK: refreshBlock,
    }
  );
  {
    id: 4,
    title: spec.form_title,
    type: 'volkovlabs-form-panel',
    gridPos: {
      h: spec.form_h,
      w: 24,
      x: 0,
      y: 4 + spec.table_h,
    },
    datasource: readDatasource,
    targets: formTargets,
    options: {
      buttonGroup: { orientation: 'center', size: 'md' },
      confirmModal: {
        title: '确认提交',
        body: '确认执行本次操作？',
        confirm: '确认',
        cancel: '取消',
        elementDisplayMode: 'all',
        columns: {
          include: ['name', 'newValue'],
          name: '字段',
          newValue: '值',
        },
      },
      elementValueChanged: elementValueChanged,
      elements: spec.elements,
      initial: {
        code: initialCode,
        contentType: 'application/json',
        getPayload: "return { rawSql: '', format: 'table' };",
        highlight: false,
        highlightColor: 'red',
        method: 'query',
        payload: {},
      },
      layout: {
        orientation: 'horizontal',
        padding: 10,
        sectionVariant: 'default',
        variant: 'single',
      },
      reset: { icon: 'process', text: '重置', variant: 'secondary' },
      resetAction: {
        code: 'context.panel.initialRequest();',
        confirm: false,
        getPayload: 'return {};',
        mode: 'initial',
        payload: {},
      },
      saveDefault: { icon: 'save', text: 'Save Default', variant: 'hidden' },
      submit: { icon: 'save', text: '提交', variant: 'primary' },
      sync: true,
      update: {
        code: updateCode,
        confirm: true,
        contentType: 'application/json',
        datasource: writeDatasource,
        getPayload: spec.get_payload_code,
        method: 'datasource',
        payload: {
          editorMode: 'code',
          format: 'table',
          rawQuery: true,
          rawSql: spec.update_raw_sql,
          refId: 'A',
          sql: sqlMeta(50),
        },
        payloadMode: 'custom',
      },
      updateEnabled: 'auto',
    },
    pluginVersion: '6.3.1',
  };

local buildDashboard(spec) =
  local templating = {
    list: [
      queryVar(spec.edit_var, spec.edit_query),
      textboxVar(spec.last_var),
      textboxVar(spec.last_ts_var),
      textboxVar(spec.delete_var),
    ],
  };
  local status = statusPanel(spec);
  local table = tablePanel(spec);
  local form = formPanel(spec);
  local panels = if spec.status_after_form then [navPanel, table, form, status] else [navPanel, status, table, form];
  {
    id: null,
    uid: spec.uid,
    title: spec.title,
    tags: spec.tags,
    timezone: 'browser',
    schemaVersion: 39,
    version: spec.version,
    refresh: '30s',
    editable: true,
    time: { from: 'now-24h', to: 'now' },
    templating: templating,
    annotations: commonAnnotations,
    panels: panels,
  };

local specs = {
  plant: {
    uid: 'iot-v1-admin-plant',
    title: 'IoT V1 Admin · Plant',
    tags: ['iot', 'admin', 'plant', 'point'],
    version: 2,
    object_cn: '厂站',
    status_cn: '厂站',
    edit_var: 'edit_plant_id',
    delete_var: 'row_delete_plant_id',
    last_var: 'last_plant_action',
    last_ts_var: 'last_plant_action_ts',
    edit_query: 'SELECT plant_id FROM plant ORDER BY plant_id;',
    table_id_field: 'plant_id',
    table_title: '厂站列表（行内编辑/删除）',
    table_h: 10,
    table_sql: |||
  SELECT plant_id, plant_name, timezone, longitude, latitude, point_count, device_count, created_at,
         '编辑' AS edit,
         '删除' AS delete
  FROM admin_api.v_plant_list
  ORDER BY created_at DESC
  LIMIT 200;
|||,
    form_title: '厂站编辑（新增/修改）',
    form_h: 12,
    form_query_sql: "SELECT plant_id, plant_name, COALESCE(longitude::text,'') AS longitude, COALESCE(latitude::text,'') AS latitude, timezone FROM plant WHERE plant_id = ${edit_plant_id:sqlstring} LIMIT 1;",
    form_pick_sql: "SELECT '' AS value, '（新建）' AS label UNION ALL SELECT plant_id AS value, plant_id AS label FROM plant ORDER BY label;",
    extra_targets: [],
    pick_id: 'plant_pick',
    reset_form_value: "{ plant_id: '', plant_name: '', longitude: '', latitude: '', timezone: 'Asia/Shanghai' }",
    elements: [
      selectQueryElement('plant_pick', '选择已有厂站', 'plant_pick', 'B', 'plant_id', '', false),
      simpleElement('plant_id', 'plant_id（可新建）', 'string', 'plant_id', '', 'plant_id'),
      simpleElement('plant_name', 'plant_name', 'string', 'plant_name', '', 'plant_name'),
      simpleElement('longitude', 'longitude', 'string', 'longitude', '', 'longitude'),
      simpleElement('latitude', 'latitude', 'string', 'latitude', '', 'latitude'),
      simpleElement('timezone', 'timezone', 'string', 'timezone', '', 'timezone'),
    ],
    get_payload_code: |||
  const get = (id) => context.panel.elements.find((e) => e.id === id)?.value;
  const esc = (v) => String(v ?? '').trim().replace(/'/g, "''");
  const toNumOrNull = (v) => {
    const s = String(v ?? '').trim();
    if (!s) return 'NULL';
    if (!/^-?\d+(\.\d+)?$/.test(s)) throw new Error('经纬度必须为数字');
    return s;
  };
  const plant_id = esc(get('plant_id'));
  const plant_name = esc(get('plant_name'));
  if (!plant_id || !plant_name) throw new Error('plant_id 与 plant_name 必填');
  return {
    plant_id,
    plant_name,
    longitude_sql: toNumOrNull(get('longitude')),
    latitude_sql: toNumOrNull(get('latitude')),
    timezone: esc(get('timezone') || 'Asia/Shanghai'),
  };
|||,
    update_raw_sql: "SELECT * FROM admin_api.upsert_plant('${payload.plant_id}', '${payload.plant_name}', ${payload.longitude_sql}, ${payload.latitude_sql}, '${payload.timezone}');",
    delete_confirm: "'确认删除厂站 ' + autoId + '（非强制删除：存在下属设备时会拒绝）？'",
    delete_raw_sql: "\"SELECT * FROM admin_api.delete_plant(${row_delete_plant_id:sqlstring}, false);\"",
    delete_object_field: 'plant_id',
    delete_detail_expr: "'级联点位 ' + Number(row.deleted_point_count ?? 0) + '，级联设备 ' + Number(row.deleted_device_count ?? 0)",
    object_id_field: 'plant_id',
    status_panel_id: 2,
    status_after_form: false,
  },

  point: {
    uid: 'iot-v1-admin-point',
    title: 'IoT V1 Admin · Point',
    tags: ['iot', 'admin', 'plant', 'point'],
    version: 2,
    object_cn: '点位',
    status_cn: '点位',
    edit_var: 'edit_point_id',
    delete_var: 'row_delete_point_id',
    last_var: 'last_point_action',
    last_ts_var: 'last_point_action_ts',
    edit_query: 'SELECT point_id FROM point ORDER BY point_id;',
    table_id_field: 'point_id',
    table_title: '点位列表（行内编辑/删除）',
    table_h: 12,
    table_sql: |||
  SELECT point_id, plant_id, plant_name, point_type, point_name, device_count, created_at,
         '编辑' AS edit,
         '删除' AS delete
  FROM admin_api.v_point_list
  ORDER BY created_at DESC
  LIMIT 300;
|||,
    form_title: '点位编辑（新增/修改）',
    form_h: 12,
    form_query_sql: "SELECT point_id, plant_id, point_type, COALESCE(point_name,'') AS point_name FROM point WHERE point_id = ${edit_point_id:sqlstring} LIMIT 1;",
    form_pick_sql: "SELECT '' AS value, '（新建）' AS label UNION ALL SELECT point_id AS value, point_id AS label FROM point ORDER BY label;",
    extra_targets: [{ refId: 'C', rawSql: 'SELECT plant_id AS value, plant_id AS label FROM plant ORDER BY plant_id;' }],
    pick_id: 'point_pick',
    reset_form_value: "{ point_id: '', point_name: '', point_type: 'inlet' }",
    elements: [
      selectQueryElement('point_pick', '选择已有点位', 'point_pick', 'B', 'point_id', '', false),
      simpleElement('point_id', 'point_id（可新建）', 'string', 'point_id', '', 'point_id'),
      selectQueryElement('plant_id', 'plant_id', 'plant_id', 'C', 'plant_id', ''),
      selectStaticElement('point_type', 'point_type', 'point_type', [{ label: 'inlet', value: 'inlet' }, { label: 'outlet', value: 'outlet' }], 'inlet', 'point_type'),
      simpleElement('point_name', 'point_name', 'string', 'point_name', '', 'point_name'),
    ],
    get_payload_code: |||
  const get = (id) => context.panel.elements.find((e) => e.id === id)?.value;
  const esc = (v) => String(v ?? '').trim().replace(/'/g, "''");
  const point_id = esc(get('point_id'));
  const plant_id = esc(get('plant_id'));
  const point_type = esc(get('point_type') || 'inlet');
  if (!point_id || !plant_id) throw new Error('point_id 与 plant_id 必填');
  const pn = String(get('point_name') ?? '').trim();
  return {
    point_id,
    plant_id,
    point_type,
    point_name_sql: pn ? `'${esc(pn)}'` : 'NULL',
  };
|||,
    update_raw_sql: "SELECT * FROM admin_api.upsert_point('${payload.point_id}', '${payload.plant_id}', '${payload.point_type}', ${payload.point_name_sql});",
    delete_confirm: "'确认删除点位 ' + autoId + '（非强制删除：存在下属设备时会拒绝）？'",
    delete_raw_sql: "\"SELECT * FROM admin_api.delete_point(${row_delete_point_id:sqlstring}, false);\"",
    delete_object_field: 'point_id',
    delete_detail_expr: "'级联设备 ' + Number(row.deleted_device_count ?? 0)",
    object_id_field: 'point_id',
    status_panel_id: 2,
    status_after_form: false,
  },

  device: {
    uid: 'iot-v1-admin-device',
    title: 'IoT V1 Admin · Device',
    tags: ['iot', 'admin', 'device'],
    version: 29,
    object_cn: '设备',
    status_cn: '设备',
    edit_var: 'edit_device_id',
    delete_var: 'row_delete_device_id',
    last_var: 'last_device_action',
    last_ts_var: 'last_device_action_ts',
    edit_query: 'SELECT device_id FROM device ORDER BY device_id;',
    table_id_field: 'device_id',
    table_title: '设备列表（含连接档案，行内编辑/删除）',
    table_h: 12,
    table_sql: |||
  SELECT device_id,
         plant_id,
         point_id,
         telemetry_topic,
         cmd_topic_pattern,
         expected_client_id,
         report_interval_sec,
         align_mode,
         enabled,
         last_seen_at,
         created_at,
         '编辑' AS edit,
         '删除' AS delete
  FROM admin_api.v_device_conn_profile
  ORDER BY created_at DESC
  LIMIT 300;
|||,
    form_title: '设备编辑（新增/修改）',
    form_h: 12,
    form_query_sql: 'SELECT device_id, point_id, report_interval_sec, align_mode, enabled FROM device WHERE device_id = ${edit_device_id:sqlstring} LIMIT 1;',
    form_pick_sql: "SELECT '' AS value, '（新建）' AS label UNION ALL SELECT device_id AS value, device_id AS label FROM device ORDER BY label;",
    extra_targets: [{ refId: 'C', rawSql: "SELECT pt.point_id AS value, (pt.plant_id || ' / ' || pt.point_id) AS label FROM point pt ORDER BY pt.plant_id, pt.point_id;" }],
    pick_id: 'device_pick',
    reset_form_value: "{ device_id: '', report_interval_sec: 60, align_mode: 'floor', enabled: true }",
    elements: [
      selectQueryElement('device_pick', '选择已有设备', 'device_pick', 'B', 'device_id', '', false),
      simpleElement('device_id', 'device_id（可新建）', 'string', 'device_id', '', 'device_id'),
      selectQueryElement('point_id', 'point_id', 'point_id', 'C', 'point_id', ''),
      simpleElement('report_interval_sec', 'report_interval_sec', 'number', 'report_interval_sec', 60, 'report_interval_sec'),
      selectStaticElement('align_mode', 'align_mode', 'align_mode', [{ label: 'floor', value: 'floor' }, { label: 'round', value: 'round' }], 'floor', 'align_mode'),
      simpleElement('enabled', 'enabled', 'boolean', 'enabled', true, 'enabled'),
    ],
    get_payload_code: |||
  const get = (id) => context.panel.elements.find((e) => e.id === id)?.value;
  const esc = (v) => String(v ?? '').trim().replace(/'/g, "''");
  const device_id = esc(get('device_id'));
  const point_id = esc(get('point_id'));
  if (!device_id || !point_id) throw new Error('device_id 与 point_id 必填');
  const iv = Number(get('report_interval_sec') ?? 60);
  if (!Number.isFinite(iv) || iv < 1 || iv > 3600) throw new Error('report_interval_sec 必须在 1~3600');
  return {
    device_id,
    point_id,
    interval_sql: String(Math.round(iv)),
    align_mode: esc(get('align_mode') || 'floor'),
    enabled_sql: get('enabled') ? 'true' : 'false',
  };
|||,
    update_raw_sql: "SELECT * FROM admin_api.upsert_device('${payload.device_id}', '${payload.point_id}', ${payload.interval_sql}, '${payload.align_mode}', ${payload.enabled_sql});",
    delete_confirm: "'确认删除设备 ' + autoId + '？'",
    delete_raw_sql: "\"SELECT * FROM admin_api.delete_device(${row_delete_device_id:sqlstring});\"",
    delete_object_field: 'device_id',
    delete_detail_expr: "'级联数量 0'",
    object_id_field: 'device_id',
    status_panel_id: 8,
    status_after_form: true,
  },

  metric: {
    uid: 'iot-v1-admin-metric',
    title: 'IoT V1 Admin · Metric Dictionary',
    tags: ['iot', 'admin', 'metric'],
    version: 27,
    object_cn: '指标',
    status_cn: '指标',
    edit_var: 'edit_metric',
    delete_var: 'row_delete_metric',
    last_var: 'last_metric_action',
    last_ts_var: 'last_metric_action_ts',
    edit_query: 'SELECT metric FROM metric_dict ORDER BY metric;',
    table_id_field: 'metric',
    table_title: '指标字典（行内编辑/删除）',
    table_h: 10,
    table_sql: "SELECT metric, display_name, unit, visible, alarm_low, alarm_high, '编辑' AS edit, '删除' AS delete FROM admin_api.v_metric_dict ORDER BY metric;",
    form_title: '指标编辑（新增/修改）',
    form_h: 10,
    form_query_sql: "SELECT metric, display_name, COALESCE(unit,'') AS unit, COALESCE(visible,true) AS visible, alarm_low, alarm_high FROM metric_dict WHERE metric = ${edit_metric:sqlstring} LIMIT 1;",
    form_pick_sql: "SELECT '' AS value, '（新建）' AS label UNION ALL SELECT metric AS value, metric AS label FROM metric_dict ORDER BY label;",
    extra_targets: [],
    pick_id: 'metric_pick',
    reset_form_value: "{ metric: '', display_name: '', unit: '', visible: true, alarm_low: null, alarm_high: null }",
    elements: [
      selectQueryElement('metric_pick', '选择已有指标', 'metric_pick', 'B', 'metric', '', false),
      simpleElement('metric', 'metric（可新建）', 'string', 'metric', '', 'metric'),
      simpleElement('display_name', 'display_name', 'string', 'display_name', '', 'display_name'),
      simpleElement('unit', 'unit', 'string', 'unit', '', 'unit'),
      simpleElement('visible', 'visible（监控页展示）', 'boolean', 'visible', true, 'visible'),
      simpleElement('alarm_low', 'alarm_low（告警下限）', 'number', 'alarm_low', null, 'alarm_low'),
      simpleElement('alarm_high', 'alarm_high（告警上限）', 'number', 'alarm_high', null, 'alarm_high'),
    ],
    get_payload_code: |||
  const get = (id) => context.panel.elements.find((e) => e.id === id)?.value;
  const esc = (v) => String(v ?? '').trim().replace(/'/g, "''");
  const toNumOrNull = (v) => {
    if (v === null || v === undefined || v === '') return 'NULL';
    const n = Number(v);
    if (!Number.isFinite(n)) throw new Error('告警上下限必须是数字');
    return String(n);
  };
  const metric = esc(get('metric')).toLowerCase();
  const display_name = esc(get('display_name'));
  if (!metric || !display_name) throw new Error('metric 与 display_name 必填');
  const u = String(get('unit') ?? '').trim();
  const visibleSql = get('visible') ? 'true' : 'false';
  const alarmLowSql = toNumOrNull(get('alarm_low'));
  const alarmHighSql = toNumOrNull(get('alarm_high'));
  if (alarmLowSql !== 'NULL' && alarmHighSql !== 'NULL' && Number(alarmLowSql) > Number(alarmHighSql)) throw new Error('alarm_low 不能大于 alarm_high');
  return { metric, display_name, unit_sql: u ? `'${esc(u)}'` : 'NULL', visible_sql: visibleSql, alarm_low_sql: alarmLowSql, alarm_high_sql: alarmHighSql };
|||,
    update_raw_sql: "SELECT * FROM admin_api.upsert_metric('${payload.metric}', '${payload.display_name}', ${payload.unit_sql}, ${payload.alarm_low_sql}, ${payload.alarm_high_sql}, ${payload.visible_sql});",
    delete_confirm: "'确认删除指标 ' + autoId + '？'",
    delete_raw_sql: "\"SELECT * FROM admin_api.delete_metric(lower(${row_delete_metric:sqlstring}));\"",
    delete_object_field: 'metric',
    delete_detail_expr: "'级联数量 0'",
    object_id_field: 'metric',
    status_panel_id: 8,
    status_after_form: true,
  },
};

{
  specs: specs,
  buildDashboard(spec): buildDashboard(spec),
}
