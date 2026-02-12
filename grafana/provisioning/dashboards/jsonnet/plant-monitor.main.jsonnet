local nav = import 'nav.libsonnet';
local dashboard = import '../v1/iot-v1-plant-monitor.json';

local patchedPanels = std.map(
  function(panel)
    if std.objectHas(panel, 'id') && panel.id == 1 then
      panel + {
        libraryPanel: {
          uid: 'lib_iot_view_nav',
          name: 'IoT Viewer Navigation',
        },
        options: (if std.objectHas(panel, 'options') then panel.options else {}) + {
          mode: 'markdown',
          content: if std.objectHas(nav, 'viewer_content') then nav.viewer_content else nav.content,
        },
      }
    else
      panel,
  dashboard.panels
);

dashboard + {
  panels: patchedPanels,
}
