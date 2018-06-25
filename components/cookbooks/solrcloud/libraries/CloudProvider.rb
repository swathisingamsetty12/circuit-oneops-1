#
# Cookbook Name :: solrcloud
# Library :: CloudProvider

require 'json'

# This class is used to implement cloud provider specific code. 
class CloudProvider

  def initialize(node)
    #get the current node's cloud name
    @cloud_name = node[:workorder][:cloud][:ciName]
    Chef::Log.info("@cloud_name : #{@cloud_name}")

    @cloud_provider = self.class.get_cloud_provider_name(node)
    Chef::Log.info("Initializing Cloud Provider : #{@cloud_provider}")

    @cloud_id_to_name_map = get_cloud_id_to_name_map(node)

    # Replica distribution varies based on cloud provider. For ex. with 'Openstack' cloud provider, we distribute replicas across clouds and witn 'Azure', 
    # replicas are distributes across domains. If no cloud provider in payload, then error out. 
    if @cloud_provider == nil || @cloud_provider.empty?
      raise "Replica distribution varies based on cloud provider and hence cloud provider must be present in compute service at cloud level."
    end
    #get the current node's compute
    managedVia_compute = node.workorder.payLoad.ManagedVia[0]
   
    case @cloud_provider
      when /azure/
      # get zone info for 'azure' cloud provider
        zone = (managedVia_compute[:ciAttributes].has_key?"zone")?JSON.parse(managedVia_compute[:ciAttributes][:zone]):{}
        Chef::Log.info("zone = #{zone.to_json}")
        if zone == nil
          raise "Missing zone information for azure cloud at compute."
        end
        @fault_domain = zone['fault_domain']
        @update_domain = zone['update_domain']
        if @fault_domain == nil || @fault_domain.to_s.empty?
          raise "Missing fault_domain information for azure cloud at compute."
        end
        if @update_domain == nil || @update_domain.to_s.empty?
          raise "Missing update_domain information for azure cloud at compute."
        end
        @zone_name = "#{@fault_domain}___#{@update_domain}"
        Chef::Log.info("@zone_name : #{@zone_name}")
        # in case of azure, key -> fault_domain
        @zone_to_compute_ip_map = get_fault_domain_to_compute_ip_map(node)
      else #/vagrant/
        # in case of other (openstack), key -> cloud_name ex. prod-cdc5
        @zone_to_compute_ip_map = get_cloud_name_to_compute_ip_map(node)
    end
  end

  # get cloud name and computes information from the payload
  # where key-> <cloud_name> & value-> list of ips
  # For ex. {"prod-cdc5":[ip1, ip2],"prod-cdc6":[ip3, ip4]}
  def get_cloud_name_to_compute_ip_map(node)
    clouds = get_clouds_payload(node)
    Chef::Log.info("clouds = #{clouds.to_json}")
   
    #cloud_id_to_name_map=> {'35709237':'cloud1','35709238':'cloud2'}
    cloud_id_to_name_map = Hash.new
    clouds.each { |cloud|
      cloud_id_to_name_map[cloud[:ciId].to_s] = cloud[:ciName]
    }
    Chef::Log.info "cloud_id_to_name_map = #{cloud_id_to_name_map.to_json}"

    cloud_name_to_ip_map = Hash.new()
    computes = self.class.get_computes_payload(node)
    computes.each do |compute|
      
      # compute[:ciName] == nil meaning compute has not provisioned yet
      next if compute[:ciName].nil?
      # Example compute[:ciName]:  compute-35709237-2

      # extract cloud_id from compute ciName. i.e. cloud_id = 35709237
      cloud_id = compute[:ciName].split('-').reverse[1].to_s

      # get cloud_name for cloud_id from cloud_id_to_name_map. i.e. cloud_name = cloud1
      cloud_name = cloud_id_to_name_map[cloud_id]

      if (cloud_name_to_ip_map[cloud_name] == nil)
        cloud_name_to_ip_map[cloud_name] = Array.new
      end

      # add private_ip to cloud_name_to_ip_map
      if compute[:ciAttributes][:private_ip] != nil
        cloud_name_to_ip_map[cloud_name].push(compute[:ciAttributes][:private_ip])
      end
    end
    Chef::Log.info("cloud_name_to_ip_map: #{cloud_name_to_ip_map.to_json}")
    return cloud_name_to_ip_map
  end

  # get fault domain and computes map information from the payload
  #[
  #  {
  #    "ciAttributes": {
  #      "private_ip": "ip1",
  #      "zone": {
  #        "fault_domain": 0,
  #        "update_domain": 1
  #      }
  #    }
  #  },
  #  {
  #    "ciAttributes": {
  #      "private_ip": "ip2",
  #      "zone": {
  #        "fault_domain": 1,
  #        "update_domain": 2
  #      }
  #    }
  #  },
  #  {
  #    "ciAttributes": {
  #      "private_ip": "ip3",
  #      "zone": {
  #        "fault_domain": 0,
  #        "update_domain": 3
  #      }
  #    }
  #  },
  #  {
  #    "ciAttributes": {
  #      "private_ip": "ip4",
  #      "zone": {
  #        "fault_domain": 1,
  #        "update_domain": 4
  #      }
  #    }
  #  }
  #]
  # This method returns the result as {0=>["ip1","ip3"],1=>["ip2","ip4"]}
  def get_fault_domain_to_compute_ip_map(node)
    
    fault_domain_to_ip_map = Hash.new
    computes = self.class.get_computes_payload(node)

    computes.each do |compute|
      next if compute[:ciAttributes][:private_ip].nil?
      if self.class.zone_info_missing?(compute)
        raise "Zone attrribute with fault_domain/update_domain information is required."
      end
      zone  = JSON.parse(compute['ciAttributes']['zone'])
      fault_domain = zone['fault_domain']
      if !fault_domain_to_ip_map.has_key?fault_domain
        fault_domain_to_ip_map[fault_domain] = []
      end
      fault_domain_to_ip_map[fault_domain].push compute[:ciAttributes][:private_ip]
    end
    
    Chef::Log.info("fault_domain_to_ip_map = #{fault_domain_to_ip_map.to_json}")
    return fault_domain_to_ip_map
  end
  
  def get_zone_to_compute_ip_map()
    return @zone_to_compute_ip_map
  end

  # check if 'zone' attribute and/or its details are missing at compute
  def self.zone_info_missing?(compute)
    # check if 'zone' attribute is missing at compute
    if compute['ciAttributes']['zone'].nil?
      return true
    end
    # check if 'fault_domain' or 'update_domain' attribute is null/empty at
    zone  = JSON.parse(compute['ciAttributes']['zone'])
    if zone['fault_domain'].nil? || zone['fault_domain'] == '' || zone['update_domain'].nil? || zone['update_domain'] == ''
      return true
    end
    return false
  end

  # get <fault_domain>_<update_domain> from compute
  def get_zone_info(compute)
    zone  = JSON.parse(compute['ciAttributes']['zone'])
    return "#{zone['fault_domain']}_#{zone['update_domain']}"
  end

  # get compute payload from workorder
  def self.get_computes_payload(node)
    return node.workorder.payLoad.has_key?("RequiresComputes") ? node.workorder.payLoad.RequiresComputes : node.workorder.payLoad.computes
  end
  
  # This method may be called from solrcloud or solr-collection recipe and both resources in pack has cloud payload with
  # different names. for ex. solrcloud's cloud payload has name 'CloudPayload' & solr-collection's cloud payload is 'Clouds'
  # hence it should fetch the payload with name 'Clouds' if it exists otherwise 'CloudPayload'
  def get_clouds_payload(node)
    return node.workorder.payLoad.has_key?("Clouds") ? node.workorder.payLoad.Clouds : (node.workorder.payLoad.has_key?("CloudPayload") ? node.workorder.payLoad.CloudPayload : nil)
  end
  
  #extract cloud provider 'Openstack/Azure' from compute service string {"prod-cdc5":{"ciClassName":"cloud.service.Openstack"}}
  def self.get_cloud_provider_name(node)
    #Chef::Log.info("node[:workorder][:services][:compute] = #{node[:workorder][:services][:compute].to_json}")
    cloud_name = node[:workorder][:cloud][:ciName]
    if !node[:workorder][:services].has_key?("compute")
      error = "compute service is missing in the cloud services list, please make sure to do pull pack and design pull so that compute service becomes available"
      puts "***FAULT:FATAL=#{error}"
      raise error
    end
    cloud_provider_name = node[:workorder][:services][:compute][cloud_name][:ciClassName].gsub("cloud.service.","").downcase.split(".").last
    Chef::Log.info("Cloud Provider: #{cloud_provider_name}")
    return cloud_provider_name
  end
  
  # In case of Azure, this method validates if 'volume-blockstorage' mount point is set as 'installation_dir_path' from solrcloud and 'volume-app'
  # is set to something other than 'installation_dir_path' which will not be used
  def self.enforce_storage_use(node, blockstorage_mount_point, volume_app_mount_point)
    Chef::Log.info("blockstorage_mount_point = #{blockstorage_mount_point}")
    Chef::Log.info("volume_app_mount_point = #{volume_app_mount_point}")
    # For example expected blockstorage_mount_point is '/app/' which is expected to be same as installation dir on solrcloud attr
    if blockstorage_mount_point == nil || blockstorage_mount_point.empty?
      error = "Blockstorage is not selected. It is required on azure. Please add volume-blockstorage with correct mount point & storage if not added already or If you still want to use ephemeral, please select the flag 'Allow ephemeral on Azure' in solrcloud component"
      puts "***FAULT:FATAL=#{error}"
      raise error
    end
      
    # For azure, we want to set '/app/' as storage mount point so that all binaries, logs & data are kept on block storage
    installation_dir_path = node["installation_dir_path"] # expected as '/app'
    #remove all '/' from installation_dir_path & blockstorage_mount_point. For. ex. '/app/' => 'app' 
    volume_app = volume_app_mount_point.delete '/'
    installation_dir = installation_dir_path.delete '/'
    blockstorage_dir = blockstorage_mount_point.delete '/'
    
    if volume_app == installation_dir
      error = "On azure, ephemeral is not used and blockstorage will be used to store data as well as logs & binaries. Hence please change the mount point on volume-app to something other than '#{installation_dir_path}' for example `/app-not-used/` and mount pount on volume-blockstorage to '#{installation_dir_path}'"
      puts "***FAULT:FATAL=#{error}"
      raise error
    end
    
    if blockstorage_dir != installation_dir
      error = "Blockstorage mount point must be same as solrcloud installation dir i.e. /#{installation_dir_path}/."
      puts "***FAULT:FATAL=#{error}"
      raise error
    end
  end

  # Shows fault domain and update domain for each solrcloud component.
  def self.show_faultdomain_and_updatedomain(node)
    computes = self.get_computes_payload(node)
    computes.each do |compute|
      if self.zone_info_missing?(compute)
        raise "Zone attrribute with fault_domain/update_domain information is required."
      end
      if compute[:ciAttributes][:private_ip] == node['ipaddress']
        zone  = JSON.parse(compute['ciAttributes']['zone'])
        fault_domain = zone['fault_domain']
        update_domain = zone['update_domain']
        Chef::Log.info(" Fault Domain = #{fault_domain}" + ", Update Domain = #{update_domain}")
        puts "***RESULT:fault_domain=#{fault_domain}"
        puts "***RESULT:update_domain=#{update_domain}"
      end
    end
  end

  def get_cloud_id_to_name_map(node)
    clouds = get_clouds_payload(node)
    # Ex: cloud_id_to_name_map => {'35709237':'prod-cdc5','35709238':'prod-cdc6'}
    cloud_id_to_name_map = Hash.new
    clouds.each { |cloud|
      cloud_id_to_name_map[cloud[:ciId].to_s] = cloud[:ciName]
    }
    return cloud_id_to_name_map
  end

  # This method returns the below detailed map of cores hosted on each node(IP address)
  # faultdomain_to_updatedomain_ip_cores_map: {"FD1":{"UD1":{"10.74.2.103":["cart, shard1, core_node1"]}},"FD0":{"UD0":{"10.74.2.31":["cart, shard2, core_node2"]}}}
  def get_faultdomain_to_updatedomain_ip_cores_map(compute_ip_to_cloud_domain_map, clusterstatus_resp_obj)
    # Capture a detailed information about UDs, IPs, Cores per fault domain
    collections = clusterstatus_resp_obj["cluster"]["collections"]
    faultdomain_to_updatedomain_ip_cores_map = Hash.new
    collections.each { |coll_name, coll_info|
      shards = coll_info["shards"]
      shards.each { |shard_name, shard_info|
        replicas = shard_info["replicas"]
        replicas.each { |replica_name, replica_info|
          node_name = replica_info["node_name"]
          ip = node_name.slice(0, node_name.index(':'))
          cloud_domain = compute_ip_to_cloud_domain_map[ip]
          fault_domain = cloud_domain.split('___')[0]
          update_domain = cloud_domain.split('___')[1]
          if !faultdomain_to_updatedomain_ip_cores_map.has_key?"FD#{fault_domain}"
            faultdomain_to_updatedomain_ip_cores_map["FD#{fault_domain}"] = Hash.new
          end
          if !faultdomain_to_updatedomain_ip_cores_map["FD#{fault_domain}"].has_key?"UD#{update_domain}"
            faultdomain_to_updatedomain_ip_cores_map["FD#{fault_domain}"]["UD#{update_domain}"] = Hash.new
          end
          if !faultdomain_to_updatedomain_ip_cores_map["FD#{fault_domain}"]["UD#{update_domain}"].has_key?ip
            faultdomain_to_updatedomain_ip_cores_map["FD#{fault_domain}"]["UD#{update_domain}"][ip] = []
          end
          faultdomain_to_updatedomain_ip_cores_map["FD#{fault_domain}"]["UD#{update_domain}"][ip].push(coll_name + ", " + shard_name + ", " + replica_name)
        }
      }
    }
    return faultdomain_to_updatedomain_ip_cores_map
  end

  # This method prints the summary and detailed information about UDs, IPs, Cores
  def print_faultdomain_to_updatedomain_summary_map(faultdomain_to_updatedomain_ip_cores_map)
    fault_domain_map = Hash.new
    faultdomain_to_updatedomain_map = Hash.new
    cluster_cores = 0
    cluster_ips = 0
    # Capture a summary information about UDs, IPs, Cores per fault domain and IPs, Cores per update domain in each fault domain
    faultdomain_to_updatedomain_ip_cores_map.each { |fault_domain, update_domain_ip_cores_map|
      cores_per_cloud = 0
      cloud_cores = 0
      cloud_ips = 0
      update_domain_ip_cores_map.each { |update_domain, ip_cores_map|
        cores_per_update_domain = 0
        ip_cores_map.each { |ip, cores|
          cores_per_update_domain = cores_per_update_domain + cores.length
        }
        if !faultdomain_to_updatedomain_map.has_key?fault_domain
          faultdomain_to_updatedomain_map[fault_domain] = Hash.new
        end
        if !faultdomain_to_updatedomain_map[fault_domain].has_key?update_domain
          faultdomain_to_updatedomain_map[fault_domain][update_domain] = Hash.new
        end
        # Capture total no IPs and Cores per fault domain and update domain
        faultdomain_to_updatedomain_map[fault_domain][update_domain] = "IPs:#{ip_cores_map.keys.size}, CORES:#{cores_per_update_domain}"
        cloud_cores = cloud_cores + cores_per_update_domain
        cloud_ips = cloud_ips + ip_cores_map.keys.size
      }
      cluster_cores = cluster_cores + cloud_cores
      cluster_ips = cluster_ips + cloud_ips
      if !fault_domain_map.has_key?fault_domain
        fault_domain_map[fault_domain] = Hash.new
      end
      # Capture total no UDs, IPs and Cores per fault domain
      fault_domain_map[fault_domain] = "UDs:#{update_domain_ip_cores_map.keys.size}, IPs:#{cloud_ips}, CORES:#{cloud_cores}"
    }

    # Show both the summary and the detailed information as both are helpful for verification
    # Ex: fault_domain_map: {"FD0":"UDs:2, IPs:2, CORES:4","FD1":"UDs:1, IPs:1, CORES:2","FD2":"UDs:1, IPs:1, CORES:2"}
    Chef::Log.info("Verify fault_domain_map: #{fault_domain_map.to_json}")
    # Ex: faultdomain_to_updatedomain_map: {"FD0":{"UD3":"IPs:1, CORES:2","UD0":"IPs:1, CORES:2"},"FD1":{"UD1":"IPs:1, CORES:2"},"FD2":{"UD2":"IPs:1, CORES:2"}}
    Chef::Log.info("Verify faultdomain_to_updatedomain_map: #{faultdomain_to_updatedomain_map.to_json}")
    # Ex: faultdomain_to_updatedomain_ip_cores_map: {"FD1":{"UD1":{"10.74.2.103":["item, shard1, core_node1","cart, shard2, core_node2"]}},
    # "FD0":{"UD3":{"10.74.2.31":["item, shard2, core_node3","cart, shard1, core_node4"]},"UD0":{"10.74.2.102":["item, shard3, core_node5","cart, shard3, core_node6"]}},
    # "FD2":{"UD2":{"10.74.2.33":["cart, shard1, core_node7","cart, shard3, core_node8"]}}}
    Chef::Log.info("Verify faultdomain_to_updatedomain_ip_cores_map: #{faultdomain_to_updatedomain_ip_cores_map.to_json}")
  end

  # Shows a summary of the allocations done for all collections
  def show_summary(compute_ip_to_cloud_domain_map, clusterstatus_resp_obj)
    if (@cloud_provider == "azure")
      faultdomain_to_updatedomain_ip_cores_map = get_faultdomain_to_updatedomain_ip_cores_map(compute_ip_to_cloud_domain_map, clusterstatus_resp_obj)
      print_faultdomain_to_updatedomain_summary_map(faultdomain_to_updatedomain_ip_cores_map)
    else
      cloud_ip_cores = Hash.new
      @zone_to_compute_ip_map.each { |cloud_name, computes|
        cloud_ip_cores[cloud_name] = Hash.new
        computes.each { |ip|
          cloud_ip_cores[cloud_name][ip] = Array.new
        }
      }
      collections = clusterstatus_resp_obj["cluster"]["collections"]
      collections.each { |coll_name, coll_info|
        shards = coll_info["shards"]
        shards.each { |shard_name, shard_info|
          replicas = shard_info["replicas"]
          replicas.each { |replica_name, replica_info|
            node_name = replica_info["node_name"]
            ip = node_name.slice(0, node_name.index(':'))
            cloud_domain = compute_ip_to_cloud_domain_map[ip]
            cloud_id = cloud_domain.split('___')[0]
            cloud_name = @cloud_id_to_name_map[cloud_id]
            cloud_ip_cores[cloud_name][ip].push(coll_name + ", " + shard_name + ", " + replica_name)
          }
        }
      }
      cloud_numcores_map = Hash.new
      cluster_cores = 0
      cloud_ip_cores.each { |cloud_name, cloud_info|
        core_per_cloud = 0
        cloud_info.each { |ip, cores|
          core_per_cloud = core_per_cloud + cores.length
        }
        cluster_cores = cluster_cores + core_per_cloud
        cloud_numcores_map[cloud_name] = core_per_cloud
      }
      # Show both the summary and the detailed information as both are helpful for verification.
      # Ex: Verify cloud_numcores_map => {"prod-cdc6":3,"prod-cdc5":3}
      Chef::Log.info("Verify cloud_numcores_map => #{cloud_numcores_map.to_json}")
      # Ex: Verify cloud_ip_cores => {"prod-cdc5":{"ip_11":["qw, shard1, core_node3"],"ip_22":["qw, shard2, core_node6"],"ip_33":[qw, shard2, core_node5]},
      # "prod-cdc6":{"ip21":["qw, shard1, core_node1"],"ip22":["qw, shard1, core_node2"],"ip23":["qw, shard2, core_node4"]}
      Chef::Log.info("Verify cloud_ip_cores => #{cloud_ip_cores.to_json}")
    end
  end

end

