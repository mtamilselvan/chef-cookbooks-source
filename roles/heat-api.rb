name "heat-api"
description "heat api"
run_list(
  "role[base]",
  "recipe[heat::heat-api]",
  "recipe[openstack-monitoring::heat-api]"
)

