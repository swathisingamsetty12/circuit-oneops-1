require 'rubygems'
require 'net/https'
require 'json'

cloud_name = node[:workorder][:cloud][:ciName]
Chef::Log::info("Cloud name is " + cloud_name)

smesh_service = node[:workorder][:services][:servicemeshcloudservice]
if !smesh_service.nil? && !smesh_service[cloud_name].nil?
  mesh_cloud_service = node[:workorder][:services][:servicemeshcloudservice][cloud_name][:ciAttributes]
  Chef::Log::info("mesh_artifact_url == " + mesh_cloud_service[:mesh_artifact_url])
else
  Chef::Log.error("servicemeshcloudservice cloud service not defined for this cloud, so cannot proceed with deployment")
  exit 1
end

### Create service mesh root directory ###
serviceMeshRootDir = "#{node['service-mesh']['service-mesh-root']}"
Chef::Log::info("Creating the root directory for service mesh #{serviceMeshRootDir} if not present...")
directory serviceMeshRootDir do
	owner 'root'
	group 'root'
	mode '0777'
	recursive true
	action :create
end
Chef::Log::info("Service mesh root directory created successfully")

linkerdConfigPath = serviceMeshRootDir + "/linkerd-sr.yaml"

### parse all tenants and make available for linkerd config template ###
allTenants = []
  JSON.parse("#{node['service-mesh']['tenants']}").each do |l|
    larr = l.split(" ")
    allTenants.push(larr)
  end

if allTenants.length < 1
  Chef::Log.error("No tenant information was provided, cannot proceed with deployment")
  exit 1
end

stratiAppName = ""
tenantConfigs = ""
allTenants.each do |a_tenant|
    if a_tenant.length < 2
        Chef::Log.error("Incomplete tenant information was provided, cannot proceed with deployment. Please provide at-least application-key and environment-name for a tenant.")
        exit 1
    end
    
    tenantConfigs = tenantConfigs + "  - appKey: #{a_tenant[0]}" + "\n"
    tenantConfigs = tenantConfigs + "    envName: #{a_tenant[1]}\n"
    
    if a_tenant.length > 2
        Chef::Log::info("Got ingress address in the tenant input text")
        tenantConfigs = tenantConfigs + "    ingressAddr: #{a_tenant[2]}\n"
    end
    
    if a_tenant.length > 3
        Chef::Log::info("Got ecv uri in the tenant input text")
        tenantConfigs = tenantConfigs + "    ecvUri: #{a_tenant[3]}\n"
    end
    
    stratiAppName = "#{a_tenant[0]}-Mesh"
end

template linkerdConfigPath do
  source 'linkerd-sr-yaml.erb'
  variables(:tenant_configs => "#{tenantConfigs}")
end

overriddenConfigYaml = node['service-mesh']['config-yaml']
Chef::Log::info("overriddenConfigYaml config-yaml: #{overriddenConfigYaml}")

overriddenConfigPath = "#{serviceMeshRootDir}/overridden-config.yaml"
Chef::Log::info("Going to create overridden config yaml at #{overriddenConfigPath}")
file overriddenConfigPath do
  content overriddenConfigYaml
  mode '0777'
  owner 'root'
  group 'root'
end
Chef::Log::info("Overridden config yaml created at #{overriddenConfigPath}")

### Download mesh jar file ###
meshRepoUrl = mesh_cloud_service[:mesh_artifact_url]
meshVersion = "#{node['service-mesh']['service-mesh-version']}"
meshJarNexusUrl = meshRepoUrl + "/" + meshVersion + "/soa-linkerd-" + meshVersion + ".jar"
Chef::Log::info("Service mesh artifact remote url: #{meshJarNexusUrl}")

remote_file "#{serviceMeshRootDir}/soa-linkerd-#{meshVersion}.jar" do
	source meshJarNexusUrl
	owner 'root'
	group 'root'
	mode '0777'
	action :create_if_missing
end

### Log and rotate
meshLogRoot = "/log/mesh"
Chef::Log::info("Creating mesh log directory for service mesh #{meshLogRoot} if not present...")
directory meshLogRoot do
  owner 'root'
  group 'root'
  mode '0777'
  recursive true
  action :create
end
Chef::Log::info("Mesh log directory created successfully")
logRotateOpt = " -log.output=#{meshLogRoot}/mesh.log -log.rollPolicy 50.megabytes -log.rotateCount 3"

### service mesh daemon ###
meshLocalPath = "#{serviceMeshRootDir}/soa-linkerd-#{node['service-mesh']['service-mesh-version']}.jar"

Chef::Log::info("Use overridden config yaml? " + node['service-mesh']['use-overridden-yaml'])
if(node['service-mesh']['use-overridden-yaml'] == "true")
  linkerdConfigPath = overriddenConfigPath
end
Chef::Log::info("Final linkerd yaml path: #{linkerdConfigPath}")

Chef::Log::info("Got addtional config as override: #{node['service-mesh']['conf-override']}")
Chef::Log::info("Adding service-mesh initd script")
template '/etc/init.d/servicemesh' do
  source 'servicemesh-init.erb'
  owner 'root'
  group 'root'
  mode 00755
  variables(:start_mesh_command => "java -Djava.net.preferIPv4Stack=true -Dsun.net.inetaddr.ttl=60 -XX:+UnlockExperimentalVMOptions -XX:+AggressiveOpts -XX:+UseConcMarkSweepGC -XX:+CMSParallelRemarkEnabled -XX:+CMSClassUnloadingEnabled -XX:+ScavengeBeforeFullGC -XX:+CMSScavengeBeforeRemark -XX:+UseCMSInitiatingOccupancyOnly -XX:CMSInitiatingOccupancyFraction=70 -XX:-TieredCompilation -XX:+UseStringDeduplication -XX:+AlwaysPreTouch -Dcom.twitter.util.events.sinkEnabled=false -Dorg.apache.thrift.readLength=10485760 -Djdk.nio.maxCachedBufferSize=262144 -Dio.netty.threadLocalDirectBufferSize=0 -Dio.netty.recycler.maxCapacity=4096 -Dio.netty.allocator.numHeapArenas=${FINAGLE_WORKERS:-8} -Dio.netty.allocator.numDirectArenas=${FINAGLE_WORKERS:-8} -Dcom.twitter.finagle.netty4.numWorkers=${FINAGLE_WORKERS:-8} -Druntime.context.system.property.override.enabled=true -Druntime.context.appName=#{stratiAppName} #{node['service-mesh']['conf-override']} -jar #{meshLocalPath} #{linkerdConfigPath} #{logRotateOpt} 2>&1 &",
            :grep_string_mesh_process => "#{node['service-mesh']['service-mesh-root']}/soa-linkerd-#{node['service-mesh']['service-mesh-version']}.jar ")
end

execute 'enableMeshDaemon' do
	command 'chkconfig --add servicemesh'
	user	'root'
end


### Start Service Mesh process ###
include_recipe "service-mesh::restart-service-mesh-process"

### Wait for process to boot up ###
Chef::Log.info("Waiting 30 seconds for mesh process to be up completely")
execute 'delay' do
  command 'sleep 30'
end

### Verify if the process started successfully ###
include_recipe "service-mesh::status"

### END ###