local admin = import 'admin.libsonnet';

{
  plant: admin.buildDashboard(admin.specs.plant),
  point: admin.buildDashboard(admin.specs.point),
  device: admin.buildDashboard(admin.specs.device),
  source: admin.buildDashboard(admin.specs.source),
  metric: admin.buildDashboard(admin.specs.metric),
}
