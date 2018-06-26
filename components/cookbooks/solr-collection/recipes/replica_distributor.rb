require 'json'
require 'net/http'

# This class is used to implement cloud provider specific code.
class ReplicaDistributor

  # [["fd1", {"ud1"=>["ip8", "ip9", "ip10", "ip11"], "ud2"=>["ip12", "ip13", "ip14", "ip15"]}], ["fd0", {"ud2"=>["ip5", "ip6", "ip7"], "ud1"=>["ip1", "ip2", "ip3", "ip4"]}]]
  # converts above array to map as below
  # {"fd1"=>{"ud1"=>["ip8", "ip9", "ip10", "ip11"], "ud2"=>["ip12", "ip13", "ip14", "ip15"]}, "fd0"=>{"ud2"=>["ip5", "ip6", "ip7"], "ud1"=>["ip1", "ip2", "ip3", "ip4"]}}
  def array_to_map(array)
    map = Hash.new
    array.each do |key, value|
      if value.kind_of?(Array)
        temp = Hash.new
        value.each {|list| temp[list[0]] = list[1]}
        map[key]=temp
      else
        map[key] = value
      end
    end
    return map
  end

  # This method returns a map {cloudid => no. of ips used by cores}
  def get_cloudid_to_used_ip_count_map(cloudId_to_ips_map, used_ip_list)
    cloudid_to_used_ips_count = Hash.new
    cloudId_to_ips_map.each do |cloudid, update_domains|
      ip_list = []
      update_domains.each {|ud, ips| ip_list.push ips}
      count = 0
      ip_list.flatten!
      ip_list.each {|ip| count = count + used_ip_list.count(ip)}
      cloudid_to_used_ips_count[cloudid] = count
    end
    return cloudid_to_used_ips_count
  end

  # This method returns the count of ips from ip_list already used by cores (from used_ip_list)
  def get_core_count(update_domain, ip_list, used_ip_list)
    c = 0
    ip_list.each {|ip| c = c + used_ip_list.count(ip)}
    return c
  end

  # This method sorts each fault domain/cloud id based on how many ips are being already used by existing collection cores.
  # Order - fault domain/cloud id with less ips used to fault domain/cloud id with more ips
  # And for each fault domain/cloud id, sorts the update domains based on how many ips are being already used by existing collection cores.
  # Order - update domain with less ips used to update domain id with more ips
  #
  # cloud_name_update_domain_to_ips_map => {"fd1"=>{"ud1"=>["ip1","ip2","ip3","ip4"],"ud2"=>["ip5","ip6","ip7"]}, "fd2"=>{"ud1"=>["ip8","ip9","ip10","ip11"],"ud2"=>["ip12","ip13","ip14","ip15"]}}
  # used_ip_list = ["ip1","ip2","ip3","ip7","ip13","ip14","ip8"]
  # cloud_name_update_domain_to_ips_map =>
  # {
  #   "fauld_domain/cloudId"=>
  #       {
  #          "update_domain"=>["ip1","ip2","ip3","ip4"],"update_domain"=>["ip5","ip6","ip7"],"update_domain"=>["ip0_4"]
  #       },
  #   "fauld_domain/cloudId"=>
  #      {
  #         "update_domain"=>["ip8","ip9","ip10","ip11"],"update_domain"=>["ip12","ip13","ip14","ip15"]
  #       }
  # }
  # Note : In Azure, cloudId is same as fault_domain
  # Note : For Openstack, there is no concept of update domain and hence compute index from ciName will be used as update domain.
  # so there will always be unique update domain witn only one ip in the update domain for Openstack
  # In above example,
  # fauld_domain 'fd1' has to total 4 ips which are already used (3 (from ud1)+ 1 (from ud2))
  # fauld_domain 'fd2' has to total 3 ips which are already used (1 (from ud1)+ 2 (from ud2))
  # fd2 has less ips used by existing replicas hence, it is more eligible to replica distribution than 'fd1'

  # For fd1, ud1=> 3, ud2=> 1, ud2 has less ips already used hence ud2 is more eligible to assign new replicas than ud1
  # For fd2, ud1=> 1, ud2=> 2, ud1 has less ips already used hence ud1 is more eligible to assign new replicas than ud2
  def sort_by_used_replicas(cloudId_to_ips_map, used_ip_list)
    puts "Cloud/Domain map before sort - #{cloudId_to_ips_map.to_json}"
    cloudid_to_used_ip_count_map = get_cloudid_to_used_ip_count_map(cloudId_to_ips_map, used_ip_list)

    # Sort the cloudids by used ip count, i.e. cloudid with less ip used is be more eligible to assign new core
    cloudId_to_ips_map = cloudId_to_ips_map.sort_by {|cloudid, update_domains| cloudid_to_used_ip_count_map[cloudid]}
    cloudId_to_ips_map = array_to_map(cloudId_to_ips_map)

    # For each cloudid/fault_domain (sorted), sort update domains
    cloudId_to_ips_map.each do |cloudId, update_domains|

      # sort update_domains so that zero/less used ips by existing replicas are more eligible than update domain with more ips already used
      update_domains = update_domains.sort_by { |update_domain, ip_list| (get_core_count(update_domain, ip_list, used_ip_list))}

      # for each update domain, sort ips so that ip with less existing replicas is more eligible than ip with more replica
      update_domains.each do |update_domain|
        update_domain[1] = update_domain[1].sort_by {|x, y| used_ip_list.count(x) }
      end

      cloudId_to_ips_map[cloudId] = update_domains
    end

    cloudId_to_ips_map = array_to_map(cloudId_to_ips_map)
    puts "Cloud/Domain map after sort - #{cloudId_to_ips_map.to_json}"
    print_cloud_ip_usage(cloudId_to_ips_map, used_ip_list)
    return cloudId_to_ips_map
  end

  def print_cloud_ip_usage(cloudId_to_ips_map, used_ip_list)
    map = Hash.new
    cloudId_to_ips_map.each do |cloudid, update_domains|
      cloudid_count = 0
      update_domain_map = Hash.new
      update_domains.each do |update_domain, ip_list|
        update_domain_count = 0
        ip_count_list = []
        ip_list.each do |ip|
          count = used_ip_list.count(ip)
          ip_count_list.push "#{ip}=>#{count}"
          update_domain_count = update_domain_count + count
        end
        update_domain_map["UD #{update_domain}=>#{update_domain_count}"]=ip_count_list
        cloudid_count = cloudid_count + update_domain_count
      end
      map["FD #{cloudid}=>#{cloudid_count}"] = update_domain_map
    end

    puts "map = #{map.to_json}"

  end

  # converts given compute list to map |ip, fault_domain/cloudid|
  # ex.
  # {"ip1_11"=>"1___1", "ip3_12"=>"1___2", "ip5_13"=>"1___3", "ip7_11"=>"1___1",
  #  "ip9_12"=>"1___2", "ip2_21"=>"2___1", "ip4_22"=>"2___2", "ip6_23"=>"2___3",
  #  "ip8_21"=>"2___1"}
  def get_compute_ip_to_cloud_id_map(computes, cloud_provider)
    compute_ip_to_cloud_id_map = Hash.new
    puts "computes in get_compute_ip_to_cloud_id_map = #{computes}"
    computes.each do |compute|
      if (compute['ciAttributes'].key?("private_ip"))
        if cloud_provider == 'azure'
          # TODO: fail if zone info missing
          zone_info = JSON.parse(compute['ciAttributes']['zone'])
          puts "zone_info = #{zone_info}"
          fault_domain = zone_info['fault_domain']
          update_domain = zone_info['update_domain']
        else
          ciName = compute['ciName']
          # 'compute-34951930-1' => "34951930"
          fault_domain = ciName.split('-')[1]
          # 'compute-34951930-1' => "1"
          update_domain = ciName.split('-')[2]
        end
        cloudId = "#{fault_domain}___#{update_domain}"
        compute_ip_to_cloud_id_map[compute['ciAttributes']['private_ip']] = cloudId
      else
        puts "compute - #{compute} - doesn't exist as the private IP value doesn't exist."
      end
    end
    return compute_ip_to_cloud_id_map
  end

  # convert given ip_list to map |cloudid , update_domain => [ip list]|
  # Example- {"1"=>{"1"=>["ip1_11", "ip7_11"], "2"=>["ip3_12", "ip9_12"], "3"=>["ip5_13"]}, "2"=>{"1"=>["ip2_21", "ip8_21"], "2"=>["ip4_22"], "3"=>["ip6_23"]}}
  def get_cloud_to_update_domain_ips_map(ip_list, compute_ip_to_cloudid_map, exclude_ip_list)
    cloud_to_update_domain_iplist_map = Hash.new
    ip_list.each do |ip|
      next if exclude_ip_list.include?ip
      cloud_name = compute_ip_to_cloudid_map[ip]
      domain = cloud_name.split("___")
      fault_domain = domain[0]
      update_domain = domain[1]
      if !cloud_to_update_domain_iplist_map.has_key?fault_domain
        cloud_to_update_domain_iplist_map[fault_domain] = Hash.new
      end
      if !cloud_to_update_domain_iplist_map[fault_domain].has_key?update_domain
        cloud_to_update_domain_iplist_map[fault_domain][update_domain] = []
      end
      cloud_to_update_domain_iplist_map[fault_domain][update_domain].push ip
    end
    return cloud_to_update_domain_iplist_map
  end

  # This function print the cloudid & count of ips in the cloud across all the update domains,
  # and for each cloudid, prints ip count in each update domain
  def print_cloudid_ip_count(cloud_to_update_domain_ips_map)
    cloud_to_update_domain_ips_map.each do |cloudid, update_domain_details|
      update_domain_log = ""
      update_domain_details.each { |update_domain, ip_list| update_domain_log = update_domain_log + "[#{update_domain} : #{ip_list.size}] " }
      puts "{cloudid : ip_count} => {#{cloudid} : #{update_domain_details.values.flatten.size}} & {update_domain : ip_count} => #{update_domain_log}"
    end
  end

  # select replica_count no of ips from given all the update domains
  def select_replicas_from_update_domains(update_domain_details_map, replica_count)
    update_domain_index = 0
    selected_ip_list = []
    for replica_index in 1..replica_count
      update_domain_numbers = update_domain_details_map.keys
      ip_list = update_domain_details_map[update_domain_numbers[update_domain_index]]
      ip_list.flatten!

      #sort by used ips, in ascending order of less used to more
      ip_list = ip_list.sort_by {|x, y| selected_ip_list.count(x) }

      # Always select the 0th ip as it has least no. of cores hosted.
      # If this ip was already selected in prev. iteration then it should have removed from the list
      ip = ip_list.fetch(0)
      selected_ip_list.push ip

      update_domain_index = update_domain_index + 1

      #If its last update domain, then start over from first update domain
      if replica_index % update_domain_details_map.size == 0
        update_domain_index = 0
      end
    end
    return selected_ip_list
  end

  # select ips from cloud to update domain map
  # cloudid_to_replica_count_map => {1 => 3, 2 => 2}, meaning select 3 ips from cloudid/fault_domain 1, & 2 from cloudid/fault_domain 2
  # Available cloudif to update domain to list of ip maps
  # ex. [["cloud1",{"update_domain1":["ip1", "ip3"]},["cloud2",{"update_domain1":["ip2", "ip4"]]
  def select_replicas_from_clouds(shard_num, cloudid_to_replica_count_map, fault_domain_to_update_domain_map)
    shard_ip_list = []
    cloudid_to_replica_count_map.each do |cloudid, replica_count|
      update_domain_details_map = fault_domain_to_update_domain_map[cloudid]
      if replica_count > 0
        if (update_domain_details_map != nil && !update_domain_details_map.empty?)
          shard_ip_list.push select_replicas_from_update_domains(update_domain_details_map, replica_count)
        else
          Chef::Log.error("Unable to select replicas for shard#{shard_num} from cloud : #{cloudid}/fault domain FD#{cloudid} because VMs/IPs are not available.")
        end
      end
    end
    return shard_ip_list.flatten
  end

  # This function returns the list of all ips on which the core is hosted for given collection
  def get_existing_collection_core_ips(collection_names, collections)
    core_ip_list = []
    if collections.empty? || collection_names.empty?
      return core_ip_list
    end
    collections.keys.each do |collection_name|
      if collection_names.include?collection_name
        collection = collections[collection_name]
        shards = collection['shards']
        shards.keys.each do |shard_name|
          core_ip_list.push shards[shard_name]['replicas'].values.collect {|x| x["node_name"].split(":")[0]}
        end
      end
    end
    return core_ip_list.flatten.uniq
  end

  # This function returns the list of all ips on which the core is hosted for given collection
  def get_existing_core_ips(collections)
    core_ip_list = []
    if collections.empty?
      return core_ip_list
    end
    collections.keys.each do |collection_name|
      collection = collections[collection_name]
      shards = collection['shards']
      shards.keys.each do |shard_name|
        core_ip_list.push shards[shard_name]['replicas'].values.collect {|x| x["node_name"].split(":")[0]}
      end
    end
    return core_ip_list.flatten
  end

  # This method return a map of shard_num => list of ips to be assigned replicas to
  def get_shard_number_to_core_ips_map(shards, replicas, computes, cloud_provider, sharing_collections, existing_collections)

    compute_ip_to_cloud_id_map = get_compute_ip_to_cloud_id_map(computes, cloud_provider)
    puts "Computes with cloud/domain information : #{compute_ip_to_cloud_id_map.to_json}"

    # ip list used by other exiting collections
    used_ip_list = get_existing_core_ips(existing_collections)
    puts "used_ip_list = #{used_ip_list}"

    if sharing_collections != nil && !sharing_collections.empty?
      puts "Option sharing is selected, hence cores will be shared with collections #{sharing_collections}"
      collection_ip_list = get_existing_collection_core_ips(sharing_collections, existing_collections)
    else
      collection_ip_list = compute_ip_to_cloud_id_map.keys
    end

    # Fail if not enough ips to assign replicas
    if (shards * replicas) > collection_ip_list.size
      raise "No enough computes to assign replicas. Computes availalable #{collection_ip_list.size} & cores to be created #{shards * replicas}"
    end

    cloud_to_update_domain_ips_map = get_cloud_to_update_domain_ips_map(collection_ip_list, compute_ip_to_cloud_id_map,skip_ip_list = [])

    cloud_to_update_domain_ips_map_sorted1 = cloud_to_update_domain_ips_map.sort_by {|fd, uds| -uds.keys.size}
    cloud_to_update_domain_ips_map_sorted1 = array_to_map(cloud_to_update_domain_ips_map_sorted1)

    replicas_per_cloud = replicas / cloud_to_update_domain_ips_map_sorted1.size
    remaining_replicas = replicas % cloud_to_update_domain_ips_map_sorted1.size
    cloud_to_replica_count = Hash.new

    # even no. of replicas per each fault_domain/cloud
    # For ex. For 10 replicas & 3 fault_domain/cloud => replicas/fault_domain = 10/3 = 3
    # For ex. For 17 replicas & 3 fault_domain/cloud => replicas/fault_domain = 17/3 = 5
    if replicas_per_cloud > 0
      for i in 0..cloud_to_update_domain_ips_map_sorted1.size-1
        cloudid = cloud_to_update_domain_ips_map_sorted1.keys.fetch(i)
        cloud_to_replica_count[cloudid] = replicas_per_cloud
      end
    end

    # Now add remaining replicas
    # Example1. For 10 replicas & 3 fault_domain/cloud => replicas/fault_domain = 10%3 = 1
    # i.e. 1 remaining replica will be distributed on 3 fault_domains as 1,0,0
    # Example2. For 17 replicas & 3 fault_domain/cloud => replicas/fault_domain = 17%3 = 2
    # i.e. 2 remaining replica will be distributed on 3 fault_domains as 1,1,0
    replica_num = 0
    while replica_num < remaining_replicas  do
      i = replica_num % cloud_to_update_domain_ips_map_sorted1.size
      cloudid = cloud_to_update_domain_ips_map_sorted1.keys.fetch(i)
      if cloud_to_replica_count[cloudid] == nil
        cloud_to_replica_count[cloudid] = 0
      end
      cloud_to_replica_count[cloudid]=cloud_to_replica_count[cloudid]+1
      replica_num +=1
    end

    # Example1. Finally for 10 replicas & 3 fault_domain/cloud => [3,3,3]+[1,0,0]=[4,3,3]
    # Example2. Finally for 17 replicas & 3 fault_domain/cloud => [5,5,5]+[1,1,0]=[6,6,5]

    cloud_to_replica_count.each { |cloudid, replica_count| puts "{cloudid : replica_to_added} => {#{cloudid} : #{replica_count}}"}

    shard_num_to_iplist_map = Hash.new
    for shard_num in 1..shards
      puts "Shard : #{shard_num} IPs to be skipped because of already added for previous shard: #{shard_num_to_iplist_map.values.flatten}"

      cloud_to_update_domain_ips_map = get_cloud_to_update_domain_ips_map(collection_ip_list, compute_ip_to_cloud_id_map,shard_num_to_iplist_map.values.flatten)
      puts "Cloud/Domain to IP details - Initially : #{cloud_to_update_domain_ips_map.to_json}"

      print_cloudid_ip_count(cloud_to_update_domain_ips_map)

      cloud_to_update_domain_ips_map_sorted = sort_by_used_replicas(cloud_to_update_domain_ips_map, used_ip_list)

      puts "cloud_to_update_domain_ips_map_sorted after using #{used_ip_list}"
      puts "#{cloud_to_update_domain_ips_map_sorted}"

      ip_list = select_replicas_from_clouds(shard_num, cloud_to_replica_count, cloud_to_update_domain_ips_map_sorted)
      ip_list.flatten!
      puts "shard_num : #{shard_num} ip list : #{ip_list}"

      if ip_list.length < replicas
        replicas_to_be_added = replicas - ip_list.length
        Chef::Log.error("Shard #{shard_num} has #{replicas_to_be_added} replica/s less than replication factor. We should add replicas manually.")
      end

      #mark these ips as used so that it will not be reconsidered again while adding replicas
      used_ip_list.push ip_list
      shard_num_to_iplist_map[shard_num] = ip_list
    end
    return shard_num_to_iplist_map
  end

end
