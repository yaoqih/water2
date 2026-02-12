local admin = import 'admin.libsonnet';

{
  plant: admin.buildDashboard(admin.specs.plant),
  point: admin.buildDashboard(admin.specs.point),
  device: admin.buildDashboard(admin.specs.device),
  metric: admin.buildDashboard(admin.specs.metric),
}
