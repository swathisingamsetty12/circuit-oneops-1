module VolumeComponent

  class Storage
    attr_accessor :storage_component,
                  :device_maps,
                  :compute_provider,
                  :storage_provider,
                  :compute_service,
                  :storage_service,
                  :instance_id,
                  :resource_group_name,
                  :compute,
                  :managed_disk_storage_type,
                  :storage_devices


    def initialize (node, storage_component, device_maps)

      @storage_component = storage_component
      @device_maps = device_maps
      @compute_provider = node[:provider_class]
      @storage_provider = node[:storage_provider_class]
      @compute_service = node[:iaas_provider]
      @storage_service = node[:storage_provider]
      ciAttr = node[:workorder][:payLoad][:ManagedVia][0][:ciAttributes]
      @instance_id = ciAttr[:instance_id].respond_to?('split') ? ciAttr[:instance_id].split('/').last : ciAttr[:instance_name]
      @resource_group_name = nil

      #set provider specific attributes
      if @storage_provider =~ /azure/
        Utils.set_proxy(node[:workorder][:payLoad][:OO_CLOUD_VARS])
        #AzureBase module is located in azure_base cookbook, volume::metadata.rb needs to depend on 'azure_base'
        #TO-DO we may want to store resource_group_name value somewhere (bom, local file, etc) so it can be re-used between cookbooks/recipes. 
        #that way we won't need that extra dependency on azure_base
        @resource_group_name = AzureBase::ResourceGroupManager.new(node).rg_name
      end

      @compute = get_compute(@storage_provider, @compute_service, @instance_id, @resource_group_name)
      @managed_disk_storage_type = nil
      @managed_disk_storage_type = @compute.managed_disk_storage_type if @storage_provider =~ /azure/

      execute_command("mkdir -p /opt/oneops/storage_devices", true)
      @storage_devices = []
      @device_maps.each do |device_maps_entry|
        storage_device = StorageDevice.new(device_maps_entry, self)
        @storage_devices.push(storage_device)
      end
    end

    def get_compute(storage_provider, compute_service, instance_id, resource_group_name = nil)
     compute = nil
     if storage_provider =~ /azure/
       compute = compute_service.servers(:resource_group => resource_group_name).get(resource_group_name, instance_id)
     else
       compute = compute_service.servers.get(instance_id)
     end
      compute
    end

    def set_provider_data_all
      Chef::Log.info("Getting storage information from provider #{@storage_provider}")
      @storage_devices.each do |storage_device|
        storage_device.set_provider_data
      end
    end

  end #class Storage

  class StorageDevice
    attr_accessor :storage_id,
                  :planned_device_id,
                  :device_prefix,
                  :status,
                  :is_attached,
                  :object

    def initialize (device_maps_entry, storage)
      #device_maps_entry is an entry in device_maps, usually in form of storage_id:device (12345:/dev/sdc)
      #Parse device_maps_entry into storage_id and device_id:
      @storage = storage
      if @storage.storage_provider =~ /azure/ && device_maps_entry.split(':').size == 5
        master_rg, storage_account_name, ciID, @slice_size, @planned_device_id = device_maps_entry.split(':')
        @storage_id = [ciID, 'datadisk', @planned_device_id.split('/').last.to_s].join('-')
      else
        @storage_id, @planned_device_id = device_maps_entry.split(':')
      end

      @device_prefix = case @storage.compute_provider
                         when /azure/; '/dev/sd'
                         when /openstack/; '/dev/vd'
                         when /ibm/; '/dev/vd'
                         when /ec2/; '/dev/sd'
                         else '/dev/xvd'
                       end

      execute_command("touch /opt/oneops/storage_devices/#{@storage_id}", true)
      @status = nil
      @is_attached = false
      @object = nil
    end

    def set_provider_data
      @is_attached = get_is_attached
    end

    def get_object_from_provider
      #Make a fog call to the provider to retrieve volume/managed_disk object
      object = nil

      if @storage.storage_provider =~ /azure/ && !@storage.managed_disk_storage_type
        object = nil

      elsif @storage.storage_provider =~ /azure/ && @storage.managed_disk_storage_type
        object = @storage.storage_service.managed_disks.get(@storage.resource_group_name, @storage_id)

      elsif @storage.storage_provider =~ /cinder|openstack/
        object = @storage.compute_service.volumes.get @storage_id

      else
        object = @storage.storage_service.volumes.get @storage_id
      end

      @object = object
      object
    end

    def get_status
      get_object_from_provider
      status = nil
      if @storage.storage_provider =~ /azure/
        status = nil
      elsif @storage.storage_provider =~ /cinder|openstack/
        status = @object.status
      else 
        status = @object.state
      end
      @status = status
      status
    end

    def get_is_attached
      get_object_from_provider
      is_attached = nil

      if @storage.storage_provider =~ /azure/ && !@storage.managed_disk_storage_type
        is_attached = true if !@storage.compute.data_disks.select{|dd| (dd.name == @storage_id)}.empty?

      elsif @storage.storage_provider =~ /azure/ && @storage.managed_disk_storage_type
        is_attached = true if @object.respond_to?('owner_id') && !@object.owner_id.nil?

      elsif @storage.storage_provider =~ /cinder|openstack/
        is_attached = true if !@object.attachments.nil? && @object.attachments.size > 0 && @object.attachments[0]['serverId'] == @storage.instance_id

      elsif @storage.compute_provider =~ /ibm/
        is_attached = true if @object.attached?
        
      elsif @storage.compute_provider =~ /rackspace/
        is_attached = true unless @storage.compute.attachments.select{|a| (a.volume_id == @storage_id)}.empty?
      end

      @is_attached = is_attached
      is_attached
    end

    def assigned_device_id
      assigned_device_id = nil
      # 1. Check in the service file
      line = execute_command("cat /opt/oneops/storage_devices/#{@storage_id}", true).stdout.chop
      assigned_device_id = line.split(':')[1] if line.split(':').size > 1

      # 2. If not found in 1, do an API call to provider to get the device
      if assigned_device_id.nil?
        volume = get_object_from_provider
        if @storage.storage_provider =~ /cinder|openstack/ &&
          !volume.attachments.nil? && volume.attachments.size > 0 &&
          volume.attachments[0].has_key?('device')
          assigned_device_id = volume.attachments[0]['device']
        elsif @storage.storage_provider =~ /azure/
          lun = @storage.compute.data_disks.detect{ |dd| (dd.name == @storage_id) }.lun
          assigned_device_id = execute_command("readlink -f /dev/disk/azure/scsi*/lun#{lun}", true).stdout.chop
        end

        # Update the service file
        set_assigned_device_id(assigned_device_id) if assigned_device_id
      end

      assigned_device_id
    end

    def set_assigned_device_id(assigned_device_id)
      execute_command("echo '#{@planned_device_id}:#{assigned_device_id}' > /opt/oneops/storage_devices/#{@storage_id}", true)
    end

    def attach (max_retry_count = 5, sleep_sec = 10)

      #storage is attached and device_id is not assigned (not determined) - means it was created with the old code - detach and re-attach
      #detach if (get_is_attached && !get_assigned_device_id)

      #storage attached and device_id is assigned - just exit
      return if (get_is_attached) # && get_assigned_device_id)

      #capture current device list from /dev
      start_time = Time.now.to_i
      Chef::Log.info("Attaching storage device #{@storage_id} with provider #{@storage.storage_provider}")
      orig_device_list = execute_command("ls -1 #{@device_prefix}*").stdout.split("\n")

      #issue attach command
      begin
        if @storage.storage_provider =~ /azure/ && !@storage.managed_disk_storage_type
          @storage.compute.attach_data_disk(@storage_id, @slice_size, @storage.compute.storage_account_name)

        elsif @storage.storage_provider =~ /azure/ && @storage.managed_disk_storage_type
          @storage.compute.attach_managed_disk(@storage_id, @storage.resource_group_name)

        elsif @storage.storage_provider =~ /cinder|openstack/
          @object.attach @storage.instance_id, @planned_device_id

        elsif @storage.compute_provider =~ /ibm/
          @storage.compute.attach(@storage_id)

        elsif @storage.compute_provider =~ /rackspace/
          rackspace_dev_id = @planned_device_id.gsub(/\d+/,"")
          @storage.compute.attach_volume @storage_id, rackspace_dev_id

        elsif @storage.compute_provider =~ /ec2/
          vol.device = @planned_device_id.gsub("xvd","sd")
          vol.server = @storage.compute

        end
      rescue  => e
        exit_with_error("Failure attaching #{@storage_id}: #{e.message}" +"\n"+ "#{e.backtrace.inspect}")
      end

      #watch /dev to capture newly added device
      #these 2 conditions have to be met to assume the attaching was successful: 
      # a) we capture assigned device id from /dev
      # b) attached status from provider is true
      cnt = 0
      device = nil
      while cnt < max_retry_count && !device
        sleep sleep_sec

        device_list = execute_command("ls -1 #{@device_prefix}*").stdout.split("\n")
        if (orig_device_list.size + 1) == device_list.size
          device = (device_list - orig_device_list).first
          set_assigned_device_id(device) if device
          Chef::Log.info("Device_id has been assigned to: #{device}")
        end
        cnt += 1
      end

      #iterated max_retry_count time but conditions are still not met - raise an error
      device = assigned_device_id
      unless get_is_attached && device
        Chef::Log.error("Original device list: #{orig_device_list.inspect.gsub("\n"," ")}, latest device list: #{device_list.inspect.gsub("\n"," ")} ")
        exit_with_error("Device_id could not be assigned in #{max_retry_count.to_s} attempts. ")
      end
      Chef::Log.info("Storage device #{@storage_id} has been successfully attached to: #{device} in #{Time.now.to_i - start_time} seconds.")
    end

    def detach_base (max_retry_count = 10, sleep_sec = 10)
      #Issue detach command
      begin
        Chef::Log.info("Detaching storage device #{@storage_id} with provider #{@storage.storage_provider}")
        if @storage.storage_provider =~ /azure/ && !@storage.managed_disk_storage_type
          @storage.compute.detach_data_disk(@storage_id)
        elsif @storage.storage_provider =~ /azure/ && @storage.managed_disk_storage_type
          @storage.compute.detach_managed_disk(@storage_id)
        elsif @storage.storage_provider =~ /cinder|openstack/
          @object.detach @storage.instance_id, @storage_id
        elsif @storage.compute_provider =~ /rackspace/
          @storage.compute.attachments.each do |a|
            Chef::Log.info("Destroying: #{a.inspect}")
            a.destroy
          end
        elsif @storage.compute_provider =~ /ibm/
          @storage.compute.detach( @storage_id )
        else
          # aws uses server_id
          if @object.server_id == instance_id
             @object.server = nil
          else
            Chef::Log.info("attached_instance_id: #{volume.server_id} doesn't match this instance_id: "+instance_id)
          end
        end

      rescue  => e
        exit_with_error("Failure detaching #{@storage_id}: #{e.message}" +"\n"+ "#{e.backtrace.inspect}")
      end

      #wait until detached or timed out
      for j in 0..max_retry_count
        if get_is_attached
          sleep sleep_sec
        else
          break
        end
      end

      if get_is_attached
        Chef::Log.error("Storage device #{storage_id} was not detached after #{sleep_sec * max_retry_count} seconds.")
      else
        execute_command("echo '#{@planned_device_id}:' > /opt/oneops/storage_devices/#{@storage_id}", true)
      end
    end

    def detach (max_retry_count = 10, sleep_sec = 10)
      start_time = Time.now.to_i
      retry_count = 0
      while retry_count < 3 && get_is_attached && get_status != 'detaching'
        detach_base(max_retry_count,sleep_sec)
        retry_count += 1
      end

      if get_is_attached
        exit_with_error("Could not detach storage device #{@storage_id}")
      else
        Chef::Log.info("Storage device #{@storage_id} has been successfully detached in #{Time.now.to_i - start_time} seconds.")
      end
    end

  end #class StorageDevice

end #module VolumeComponent
