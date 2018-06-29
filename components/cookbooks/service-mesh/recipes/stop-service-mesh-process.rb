Chef::Log.info("Stopping service mesh...")
execute 'stopServiceMesh' do
	command "#{node['service-mesh']['init-name']} stop"
	user	'root'
	returns [0,1]
	ignore_failure true
end
Chef::Log.info("Service mesh stopped successfully.")
