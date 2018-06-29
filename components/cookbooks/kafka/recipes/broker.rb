# Cookbook Name:: kafka
# Recipe:: broker.rb
#
# Copyright 2014, @WalmartLabs
#
# All rights reserved - Do Not Redistribute

# set kafka user- specified in broker.rb attribute
kafka_user = node['kafka']['user']

# set kafka config dir - specified in broker.rb attribute
kafka_config_dir = node['kafka']['config_dir']

# create kafka user
user "#{kafka_user}" do
  system true
  home "/home/kafka"
  shell "/bin/bash"
  action :create
end

# create default config dir specified above
directory "#{kafka_config_dir}" do
  owner "#{kafka_user}"
  group "#{kafka_user}"
  mode '0755'
  action :create
end

# create the kafka server app log dir
directory node['kafka']['syslog_dir'] do
  owner "#{kafka_user}"
  group "#{kafka_user}"
  recursive true
  mode '0755'
  action :create
end

persistent_storage = nil
node.workorder.payLoad[:DependsOn].each do |dep|
  Chef::Log.info("dep: " + dep["ciName"])
  if dep["ciName"] =~ /volume-persistent/
    persistent_storage = dep
    break
  end
end

if !persistent_storage.nil?
  Chef::Log.info("------------------------------------------------------")
  Chef::Log.info("persistent_storage: "+persistent_storage.inspect.gsub("\n"," "))
  Chef::Log.info("------------------------------------------------------")
  mount_point = persistent_storage['ciAttributes']['mount_point']

  dir = Dir.entries(mount_point)
  if dir.include?("kafka_logs") || dir.size <= 3 # if new deploy: the directory should has 3 folders:  ['.', '..', 'lost+found']
    node.set['kafka']['data_dir'] = mount_point + "/kafka_logs"
  else
    Chef::Log.error("the directory either not mounted or already being used (e.g. not empty directory)")
    exit 1
  end
end

# create kafka data dir
directory node['kafka']['data_dir'] do
  owner "#{kafka_user}"
  group "#{kafka_user}"
  recursive true
  mode '0755'
  action :create
end

execute "chown-kafka-data" do
  command "chown -R #{kafka_user}:#{kafka_user} #{node['kafka']['data_dir']}"
  action :run
  only_if { ::File.directory?("#{node['kafka']['data_dir']}")}
end

# changes log dir and logs to kafka user if logs are owned by root
execute "chown-kafka-logs" do
  command "chown -R #{kafka_user}:#{kafka_user} #{node['kafka']['syslog_dir']}"
  user "root"
  action :run
  only_if "/bin/find #{node['kafka']['syslog_dir']} -user root | grep '.*'"
end

brokerid, zkid, zk_electors, zk_observers = get_server_id_and_internal_zookeeper_electors

# creates broker.properties 
template "#{kafka_config_dir}/broker.properties" do
    source "broker.properties.erb"
    owner "#{kafka_user}"
    group "#{kafka_user}"
    mode  '0664'
    variables :myid => brokerid
end

# create "check_kafka_zk_conn.sh" script for nagios
template "/opt/nagios/libexec/check_kafka_zk_conn.sh" do
    source "check_kafka_zk_conn.sh.erb"
    owner "root"
    group "root"
    mode  '0755'
end

# create "kafka_logerrs.sh" script for nagios/telegraf
 template "/usr/local/kafka/bin/kafka_logerrs.sh" do
     source "kafka_logerrs.sh.erb"
     owner "root"
     group "root"
     mode  '0777'
 end

# create "kafka_segment_size.sh" script 
 template "/usr/local/kafka/bin/kafka_segment_size.sh" do
     source "kafka_segment_size.sh.erb"
     owner "root"
     group "root"
     mode  '0777'
 end
 
 # adding permissions so that kafka_logerrs.sh will be executed without erros
 bash "add permissions to kafka_logerrs.sh" do
   user "root"
   code <<-EOF
     sudo chmod 777 /usr/local/kafka/bin/kafka_logerrs.sh
     sudo mkdir -p /var/tmp/check_logfiles 
     sudo touch /var/tmp/check_logfiles/check_logfiles._var_log_kafka_server.log.kafka_errlog
     sudo chmod -R 777 /var/tmp/check_logfiles
   EOF
 end
 
 
# broker log cleanup cron
template "/etc/cron.d/delete_broker_logs" do
    source "delete_broker_logs.erb"
    owner "root"
    group "root"
    mode "0644"
end

# drops off log4j properties file for kafka
template "#{kafka_config_dir}/log4j.properties" do
    source "log4j.properties.erb"
    owner "#{kafka_user}"
    group "#{kafka_user}"
    mode  '0664'
end

Chef::Log.info("Memory is: #{node['memory']['total']}")

mem_in_GB =  node['memory']['total'].split('kB')[0].to_i / 1024 / 1024

Chef::Log.info("mem_in_GB: #{mem_in_GB}")

# JVM tune-up with different java version and memory size
if java_version.start_with? "1.7" or mem_in_GB < 6
   # UseParNewGC
   Chef::Log.info("Use UseParNewGC")
   kafka_jvm_performance_opts = "-server -XX:+UseParNewGC -XX:+UseConcMarkSweepGC -XX:+CMSClassUnloadingEnabled -XX:+CMSScavengeBeforeRemark -XX:+DisableExplicitGC -Djava.awt.headless=true"
elsif java_version.start_with? "1.8"
   # G1 GC
   Chef::Log.info("Use G1GC")
   kafka_jvm_performance_opts = "-server -XX:MetaspaceSize=96m -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35 -XX:G1HeapRegionSize=16M -XX:MinMetaspaceFreeRatio=50 -XX:MaxMetaspaceFreeRatio=80"
else
   Chef::Log.error("Java version #{java_version} is not supported. Cannot Proceed further...")
end

totalmemory = node['memory']['total'].split('kB')[0].to_i/1024

Chef::Log.info("totalmemory: #{totalmemory}mb")
Chef::Log.info("jvm memory user input: #{node['kafka']['jvm_args']}")

#kafka heap is at least 1024mb.
#if user specified a kafka heap greater than 1024, that value is honored
#if user specified no kafka heap size, 25% of total memory is assigned to kafka heap

memoryspecified = node['kafka']['jvm_args'].to_s.empty? ? 0 : node['kafka']['jvm_args'].to_i
heap_size = memoryspecified > 0 ? [memoryspecified, 1024].max : [1024, totalmemory * 0.25 ].max

Chef::Log.info("heap_size for kafka : #{heap_size.to_i}mb")

# custom init script that launches process as kafka user
template "/etc/init.d/kafka" do
    source "kafka.erb"
    owner 'root'
    group 'root'
    mode  '0755'
    variables ({
    	:kafka_jvm_performance_opts => kafka_jvm_performance_opts,
    	:heap_size => heap_size.to_i
    })
end

# create the config dir
directory "/etc/kafka" do
    owner "#{kafka_user}"
    group "#{kafka_user}"
    recursive true
    mode '0755'
    action :create
end

# overwrites log4j.properties file that gets dropped off by rpm to consolidate log location
template "/etc/kafka/log4j.properties" do
    source "kafka_log4j.properties.erb"
    owner "#{kafka_user}"
    group "#{kafka_user}"
    mode  '0755'
end

# Validatiion of Zookeeper "admin" user password for SASL
if (node['kafka']['is_zk_secured'] == "true" && node['kafka']['zk_sasl_admin_password'].strip.empty?)
  nozksasladminpass = "The password for SASL 'admin' user in External Zookeeper section can't be empty."
  Chef::Log.error("FATAL: #{nozksasladminpass}")
  puts "***FAULT:FATAL= #{nozksasladminpass}"
  Chef::Application.fatal!(nozksasladminpass)
end


# jaas conf file
template "/etc/kafka/kafka_server_jaas.conf" do
  source "kafka_server_jaas.conf.erb"
  owner "#{kafka_user}"
  group "#{kafka_user}"
  mode  '0755'
end

zk_peers = Array.new
if node.workorder.rfcCi.ciAttributes.use_external_zookeeper.eql?("false")
  zk_peers = zk_electors.keys
else
  zk_peers = node.workorder.rfcCi.ciAttributes.external_zk_url.split(",")
end

# creates server.properties
server_variables = {
   :zookeeper_cluster_peers => zk_peers,
   :ssl_properties => setup_ssl_get_props(),
}

template "#{kafka_config_dir}/server.properties" do
    source "server.properties.erb"
    owner "#{kafka_user}"
    group "#{kafka_user}"
    mode  '0664'
    variables server_variables
    #    notifies :create, 'ruby_block[coordinate-kafka-start]', :immediately
end

if node.workorder.rfcCi.ciAttributes.restart_flavor.eql?("rolling")
  # Kafka rolling restart
  Chef::Log.info("Rolling restart...")
  include_recipe "kafka::coordinate_kafka_start"
else
  service "kafka" do
    provider Chef::Provider::Service::Init
    supports  :restart => true, :status => true, :stop => true, :start => true
    action :start
    only_if { node.workorder.rfcCi.rfcAction == "add" || node.workorder.rfcCi.rfcAction == "replace" } 
  end
end
