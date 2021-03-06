#
# Cookbook Name:: keystone
# Recipe:: keystone-common
#
# Copyright 2012-2013, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Install all of keystone
execute "install_genastack_keystone" do
  command "genastack keystone"
  action :run
end

directory "/etc/keystone" do
  action :create
  owner "keystone"
  group "keystone"
  mode "0700"
end

execute "keystone-manage pki_setup" do
  user "keystone"
  group "keystone"
  command "keystone-manage pki_setup"
  action :run
  not_if {File.exists?("/etc/keystone/ssl/private/signing_key.pem")}
end

# Setting attributes inside ruby_block means they'll get set at run time
# rather than compile time; these files do not exist at compile time when chef
# is first run.
ruby_block "store key and certs in attributes" do
  block do
    if node["keystone"]["pki"]["enabled"] == true
      node.set_unless["keystone"]["pki"]["key"] = File.read("/etc/keystone/ssl/private/signing_key.pem")
      node.set_unless["keystone"]["pki"]["cert"] = File.read("/etc/keystone/ssl/certs/signing_cert.pem")
      node.set_unless["keystone"]["pki"]["cacert"] = File.read("/etc/keystone/ssl/certs/ca.pem")
    end
  end
end

# fixup the keystone.log ownership if it exists
file "/var/log/keystone/keystone.log" do
  owner "keystone"
  group "keystone"
  mode "0600"
  only_if { ::File.exists?("/var/log/keystone/keystone.log") }
end

%w{ssl ssl/certs}.each do |dir|
  directory "/etc/keystone/#{dir}" do
    action :create
    owner  "keystone"
    group  "keystone"
    mode   "0755"
  end
end

directory "/etc/keystone/ssl/private" do
  action :create
  owner  "keystone"
  group  "keystone"
  mode   "0700"
end

ks_setup_role = node["keystone"]["setup_role"]
ks_mysql_role = node["keystone"]["mysql_role"]
ks_api_role = node["keystone"]["api_role"]
keystone = get_settings_by_role(ks_setup_role, "keystone")

if node["keystone"]["pki"]["enabled"] == true
  file "/etc/keystone/ssl/private/signing_key.pem" do
    owner   "keystone"
    group   "keystone"
    mode    "0400"
    content keystone["pki"]["key"]
  end

  file "/etc/keystone/ssl/certs/signing_cert.pem" do
    owner   "keystone"
    group   "keystone"
    mode    "0644"
    content keystone["pki"]["cert"]
  end

  file "/etc/keystone/ssl/certs/ca.pem" do
    owner   "keystone"
    group   "keystone"
    mode    "0444"
    content keystone["pki"]["cacert"]
  end
end


file "/var/lib/keystone/keystone.db" do
  action :delete
end

if node.recipe? "apache2"
  # Used if SSL was or is enabled
  vhost_location = value_for_platform(
    ["ubuntu", "debian", "fedora"] => {
      "default" => "#{node["apache"]["dir"]}/sites-enabled/openstack-keystone"
    },
    "fedora" => {
      "default" => "#{node["apache"]["dir"]}/vhost.d/openstack-keystone"
    },
    ["redhat", "centos"] => {
      "default" => "#{node["apache"]["dir"]}/conf.d/openstack-keystone"
    },
    "default" => {
      "default" => "#{node["apache"]["dir"]}/openstack-keystone"
    }
  )
  # If no URI is SSL enabled check to see if vhost existed,
  # delete it and bounce httpd
  # Used when going from https -> http
  execute "Disable https" do
    command "rm -f #{vhost_location}"
    only_if { File.exists?(vhost_location) }
    notifies :restart, "service[apache2]", :delayed
    action :nothing
  end
end

ks_admin_bind = get_bind_endpoint("keystone", "admin-api")
ks_service_bind = get_bind_endpoint("keystone", "service-api")

settings = get_settings_by_role(ks_setup_role, "keystone")
mysql_info = get_mysql_endpoint(ks_mysql_role)

# only bind to 0.0.0.0 if we're not using openstack-ha w/ a keystone-admin-api VIP,
# otherwise HAProxy will fail to start when trying to bind to keystone VIP
ha_role = "openstack-ha"
vip_key = "vips.keystone-admin-api"
if get_role_count(ha_role) > 0 and rcb_safe_deref(node, vip_key)
  ip_address = ks_admin_bind["host"]
else
  ip_address = "0.0.0.0"
end

# Setup db_info hash for use in the template
db_info = {
  "user" => settings["db"]["username"],
  "pass" => settings["db"]["password"],
  "name" => settings["db"]["name"],
  "ipaddress" => mysql_info["host"]
}

ks_admin_endpoint = get_access_endpoint(ks_api_role, "keystone", "admin-api")
ks_service_endpoint = get_access_endpoint(ks_api_role, "keystone", "service-api")

notification_provider = node["keystone"]["notification"]["driver"]
case notification_provider
when "no_op"
  notification_driver = "keystone.openstack.common.notifier.no_op_notifier"
when "rpc"
  notification_driver = "keystone.openstack.common.notifier.rpc_notifier"
when "log"
  notification_driver = "keystone.openstack.common.notifier.log_notifier"
else
  msg = "#{notification_provider}, is not currently supported by these cookbooks."
  Chef::Application.fatal! msg
end

template "/etc/keystone/keystone.conf" do
  source "keystone.conf.erb"
  owner "keystone"
  group "keystone"
  mode "0600"
  variables(
    :debug => settings["debug"],
    :verbose => settings["verbose"],
    :db_info => db_info,
    :ip_address => ip_address,
    :service_port => ks_service_bind["port"],
    :admin_port => ks_admin_bind["port"],
    :admin_token => settings["admin_token"],
    :member_role_id => node["keystone"]["member_role_id"],
    :auth_type => settings["auth_type"],
    :ldap_options => settings["ldap"],
    :pki_token_signing => settings["pki"]["enabled"],
    :token_expiration => settings["token_expiration"],
    :admin_endpoint => "#{ks_admin_endpoint['scheme']}://#{ks_admin_endpoint['host']}:#{ks_admin_endpoint['port']}",
    :public_endpoint => "#{ks_service_endpoint['scheme']}://#{ks_service_endpoint['host']}:#{ks_service_endpoint['port']}",
    :notification_driver => notification_driver,
    :notification_topics => node["keystone"]["notification"]["topics"]
  )
end

# set up a token cleaning job
template "/etc/cron.d/keystone-token-cleanup" do
  source "keystone-token-cleanup.erb"
  owner "root"
  group "root"
  mode "0600"
  variables(
      "keystone_db_user" => db_info["user"],
      "keystone_db_password" => db_info["pass"],
      "keystone_db_host" => db_info["ipaddress"],
      "keystone_db_name" => db_info["name"]
  )
end
