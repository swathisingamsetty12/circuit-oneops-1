#
# Cookbook Name :: solr-collection
# Library :: solrcollection_util
#
# The recipe contains util methods.
#

module SolrCollection

  module Util

    require 'json'
    require 'net/http'
    require 'cgi'
    require 'rubygems'
    require 'rexml/document'


    include Chef::Mixin::ShellOut


    def print_and_raise_bad_response(response, path)
      Chef::Log.error("response.code: #{response.code} for URL: #{path}")
      Chef::Log.error("Response : #{response}")

      # Try to raise error.msg if available
      begin
        Chef::Log.error("Response.body : #{response.body()}")
        obj = JSON.parse(response.body())
        raise obj['error']['msg']
      rescue JSON::ParserError => e
        Chef::Log.error("response.body.error.msg not found")
        # If error.msg could not be raised, then check response.msg
        if response.msg != nil then
          raise "Error \"#{response.msg}\" occurred while executing #{path}. Check oneops logs or Solr-server logs."
        end
        raise "Unable to execute #{path}. Check oneops logs or Solr-server logs."
      end
    end


    # wrapper over get requests that throws a more informative exception
    def http_request_get(host_name, port_no, path)
      begin
        Chef::Log.info("host_name = " + host_name + ", port_no = " + port_no + ", path = " + path)
        http = Net::HTTP.new(host_name, port_no)
        request = Net::HTTP::Get.new(path)

        SolrAuth::AuthUtils.add_credentials_if_required(request)
        response = http.request(request)
        return response
      rescue Exception => exception
        Chef::Log.error("Failed in http-request (host_name=#{host_name}, port_no = #{port_no}, path=#{path}) with exception = #{exception.message}")
        raise exception
      end
    end


    # wrapper over post requests that throws a more informative exception
    def http_request_post(host_name, port_no, path, req_body)
      begin
        Chef::Log.info("host_name = " + host_name + ", port_no = " + port_no + ", path = " + path)
        http = Net::HTTP.new(host_name, port_no)
        request = Net::HTTP::Post.new(path, 'Content-Type' => 'application/json')
        request.body = req_body

        SolrAuth::AuthUtils.add_credentials_if_required(request)
        Chef::Log.info(req_body)
        response = http.request(request)
        return response
      rescue Exception => exception
        Chef::Log.error("Failed in http-request (host_name=#{host_name}, port_no = #{port_no}, path=#{path}) with exception = #{exception.message}")
        raise exception
      end
    end


    # This API is to send [CREATE, MODIFY, DELETE, ADDREPLICA, DELETEREPLICA] collection api requests.
    def collection_api(host_name, port_no, params, config_name=nil, path="/solr/admin/collections")
      if not config_name.nil?
        path = "#{path}?".concat(params.collect { |k,v| "#{k}=#{CGI::escape(v.to_s)}" }.join('&'))+"&collection.configName="+config_name+"&wt=json"
      else
        path = "#{path}?".concat(params.collect { |k,v| "#{k}=#{CGI::escape(v.to_s)}" }.join('&'))+"&wt=json"
      end

      response = http_request_get(host_name, port_no, path)
      obj = JSON.parse(response.body())
      if response.code == '200'
        if obj != nil
          return JSON.parse(response.body())
        else
          puts "URL - #{path}"
          puts "Empty Response : #{response}"
          raise response.msg
        end
      else
        print_and_raise_bad_response(response, path)
      end
    end

    # Validate schema action
    def validate_schema_action(schema_action)
      schema_actions = [
        "add-field",
        "delete-field",
        "replace-field",
        "add-dynamic-field",
        "delete-dynamic-field",
        "replace-dynamic-field",
        "add-field-type",
        "delete-field-type",
        "replace-field-type",
        "add-copy-field",
        "delete-copy-field"
      ]

      if not schema_actions.include?(schema_action)
        raise "Unsupported schema action"
      else
        Chef::Log.info("Valid schema action - #{schema_action}")
      end
    end

    # Validate property type
    def validate_property_type(property_type)
      property_types = [
        "common-property",
        "user-defined-property"
      ]

      if not property_types.include?(property_type)
        raise "Unsupported property type"
      else
        Chef::Log.info("Valid property type - #{property_type}")
      end
    end

    # Validate the json object
    def parseJSON(json_payload)
      begin
        json_object = JSON.parse(json_payload)
        Chef::Log.info("Valid JSON Object")
        return json_object
      rescue Exception => exception
        Chef::Log.error("Exception = \"#{exception.message}\" occurred while parsing JSON for string #{json_payload}")
        raise exception
      end
    end

    # Get collection state for higher versions from zookeeper.
    def get_collection_state(host_name, port_no, collection_name, params)
      cluster_status_resp = collection_api(node['ipaddress'], port_no, params)
      cluster_collections = cluster_status_resp["cluster"]["collections"]
      if not cluster_collections.empty?
        collection_state_obj = cluster_collections[collection_name]
        if not collection_state_obj.nil?
          return collection_state_obj
        end
      end
      raise StandardError, "empty response"
    end

    # This API is to set/un-set properties in solr-config.xml configuration file.
    def solr_config_api(host_name, port_no, collection_name, property_type, property_name, property_value, path="/solr")
      path = "#{path}/#{collection_name}/config"

      if (property_type == "common-property")
        if (!property_value.empty?)
          req_body = "{set-property:{#{property_name}:#{property_value}}}"
        else
          req_body = "{unset-property:#{property_name}}"
        end
      end

      if (property_type == "user-defined-property")
        if (!property_value.empty?)
          req_body = "{set-user-property:{#{property_name}:#{property_value}}}"
        else
          req_body = "{unset-user-property:#{property_name}}"
        end
      end

      response = http_request_post(host_name, port_no, path, req_body)

      if response != nil then
        if(response.code == '200')
          return true
        else
          raise "Failed to execute solr config API."
        end
      end
      raise StandardError, "empty response"
    end

    # This API is to add/modify/delete fields/field-types etc., elements in managed-schema configuration file.
    def manage_schema_api(host_name, port_no, collection_name, schema_action, json_payload, update_timeout_secs=nil, path="/solr")
      path = "#{path}/#{collection_name}/schema?update_timeout_secs=#{update_timeout_secs}"

      req_body = "{#{schema_action}:"+json_payload+"}"
      response = http_request_post(host_name, port_no, path, req_body)

      result = JSON.parse(response.body)
      errors = result['errors']
      if errors != nil && !errors.empty?
        puts "URL - #{path}"
        puts "Response : #{response}"
        raise "#{errors.to_s}"
      else
        Chef::Log.info("Successfully updated schema.")
      end
    end

    # Get collections on cluster.
    def get_cluster_collections(ip_address, port_no)
      params = {
        :action => "LIST"
      }
      cluster_collections = collection_api(ip_address, port_no, params)
      puts "cluster collections - #{cluster_collections}"
      collection_list = cluster_collections["collections"]
      return collection_list
    end

    # Create collection.
    def create_collection(port_no, params, config_name)
      collection_api_resp_obj = collection_api(node['ipaddress'], port_no, params, config_name)
      issuccess = collection_api_resp_obj.fetch('success', '')
      if issuccess.empty?
        error_msg = collection_api_resp_obj.fetch('error', '')
        message = error_msg.fetch('msg','')
        Chef::Log.raise(message)
      else
        Chef::Log.info("Successfully created collection #{collection_name}.")
      end
    end

    # Modify collection.
    def modify_collection(port_no, params)
      begin
        collection_api(node['ipaddress'], port_no, params)
      rescue
        raise "Failed to modify collection."
      ensure
        Chef::Log.info "Completed execution of modify_collection API."
      end
    end

    # Get cluster livenodes.
    def get_cluster_livenodes(port_no)
      params = {
        :action => "CLUSTERSTATUS"
      }
      livenode_iplist = Array.new()
      cluster_status_resp = collection_api(node['ipaddress'], port_no, params)
      cluster_live_nodes = cluster_status_resp["cluster"]["live_nodes"]
      cluster_live_nodes.each do |live_node|
        ipaddress = live_node.split(":")[0]
        livenode_iplist.push(ipaddress)
      end
      if not livenode_iplist.empty?
        return livenode_iplist
      end
      raise StandardError, "empty response"
    end

    def core_api(host_name, port_no, params, path="/solr/admin/cores")
      path = "#{path}?".concat(params.collect { |k,v| "#{k}=#{CGI::escape(v.to_s)}" }.join('&'))+"&wt=json"

      response = http_request_get(host_name, port_no, path)
      obj = JSON.parse(response.body())
      if response.code == '200'
        if obj != nil
          return JSON.parse(response.body())
        else
          puts "URL - #{path}"
          puts "Empty Response : #{response}"
          raise response.msg
        end
      else
        print_and_raise_bad_response(response, path)
      end
    end

    # Get the cores on node
    def get_node_solr_cores(ip_address, port_no)
      params = {:action => "STATUS"}
      node_solr_cores = core_api(ip_address, port_no, params)
      return node_solr_cores["status"].keys
    end

    # Create collection without replicas.
    def create_collection_without_replicas(port_no, params, config_name)
      collection_api_resp_obj = collection_api(node['ipaddress'], port_no, params, config_name)
      return collection_api_resp_obj
    end

    # This method checks if field name already exists. If exists with different type, then throws error
    def field_type_exists(host_name, port_no, collection_name, field, field_type)
        path = "/solr/#{collection_name}/schema/fields/#{field}"

        response = http_request_get(host_name, port_no, path)
        resp_body = JSON.parse(response.body)
        code = response.code
        Chef::Log.info("response code = #{code}")
        if code == "404"
           # field may not found
           return false
        elsif code == "200"
          field_payload = resp_body['field']
          type = field_payload['type']
          if field_type != type
            raise "Field #{field} already exists with type : #{type}"
          else
            return true
          end
        else
          error = resp_body['error']
          raise error['msg']
        end
    end

    def extract_compare_directories_and_perform_action(solr_config, config_name, extracted_config_dir, config_jar, custom_config_nexus_path, custom_dir_full_path, custom_config_dir, is_valid_date_check)

      # Extract the contents from the jar provided in URL to extracted_config_dir
      extractCustomConfig(solr_config, config_jar, custom_config_nexus_path, extracted_config_dir)

      props_map = get_prop_metadata_for_solrconfig_update()

      # This step is required before we perform the diff as the current OneOps solrconfig options should be applied
      # to the config file downloaded from given url before we perform the diff between config downloaded from given url and config downloaded from
      # zookeeper

      ruby_block 'update_solrconfig' do
        block do
          update_solrconfig_and_override_properties("#{solr_config}/#{extracted_config_dir}/solrconfig.xml", props_map, true)
        end
      end

      Chef::Log.info("Comparing the contents of both extracted and downloaded configurations.")

      # Take the diff of directory contents in the downloaded config from ZK and the extracted_config_dir which is the extracted config jar provided in url
      bash 'diff_jar_directories' do
        code <<-EOH
          cd #{solr_config}

          # We skip the configoverlay.json and the solrconfig.xml from this diff operation. The configoverlay.json file is expected to be only in the config downloaded
          # from zookeeper. Since the solrconfig.xml file is programmatically updated using the DOM api, the order of the attributes and order of elements is unpredictable.
          # We cannot rely on a plain diff for solrconfig.xml file

          diff -r --brief -x configoverlay.json -x solrconfig.xml #{solr_config}/#{config_name} #{solr_config}/#{extracted_config_dir} | sudo tee /tmp/diff_jar_directories_output.txt
          diff -r -x configoverlay.json -x solrconfig.xml #{solr_config}/#{config_name} #{solr_config}/#{extracted_config_dir} | sudo tee /tmp/diff_jar_directories_contents.txt


        EOH
        only_if { ::File.directory?("#{solr_config}/#{extracted_config_dir}") }
      end

      # Perform the diff of the solrconfig.xml file using the python script separately as the DOM API used to update the solrconfig.xml file
      # changes the order of the attributes and the order of the elements unpredictably. Due to this we cannot rely on the diff command run above
      # recursively on the 2 directories.
      # We use the xmldiffs.py script which sorts the elements and attributes and writes the xml files to an intermediate temporary file and then
      # performs a diff between these two intermediate files

      bash 'diff_solrconfig_xml' do
        code <<-EOH
          /tmp/xmldiffs.py  #{solr_config}/#{config_name}/solrconfig.xml #{solr_config}/#{extracted_config_dir}/solrconfig.xml | sudo tee /tmp/diff_solrconfig.xml.txt
        EOH
      end

      ruby_block 'check_diff_output' do
        block do

          # If diff_jar_directories_output.txt exist write the contents of the file to the log (Output of diff -r --brief)
          # Note: If there is a retry logic from Oneops happens after the first pass through the below logic,
          # then these files won't have the diff output since the updated config from given url is already uploaded to ZK in the first pass.
          if File.exists?("/tmp/diff_jar_directories_output.txt")
            diff_output = File.open('/tmp/diff_jar_directories_output.txt').read
            diff_output.gsub!(/\r\n?/, "\n")
            Chef::Log.info("Diff output from extracted and downloaded configurations is given below : ")
            diff_output.each_line do |line|
              Chef::Log.info("Diff output - #{line}")
            end
            Chef::Log.info("See /tmp/diff_jar_directories_contents.txt for actual diffs.")
          end

          # Output the diff of solrconfig.xml file to the Chef logs
          if File.exists?("/tmp/diff_solrconfig.xml.txt")
            diff_output = File.open('/tmp/diff_solrconfig.xml.txt').read
            diff_output.gsub!(/\r\n?/, "\n")
            Chef::Log.info("Diff output from the two solrconfig.xml files is given below: ")
            diff_output.each_line do |line|
              Chef::Log.info("Diff output - #{line}")
            end
            Chef::Log.info("See /tmp/diff_solrconfig.xml.txt for actual diffs.")
          end

          # If diff -r --brief doesn't give any output and if there is no diff in the solrconfig.xml file, then inform user that there is no change in the configuration which is already uploaded.
          if File.zero?("/tmp/diff_jar_directories_output.txt") and File.zero?("/tmp/diff_solrconfig.xml.txt")
            Chef::Log.warn("Config in zookeeper is same as the one downloaded from given url. Hence skipping the upload of configuration to zookeeper.")
          else
            if is_valid_date_check
              Chef::Log.info("Noticed some change in the configuration. So uploading the updated configuration to ZK.")
              extracted_config_dir_full_path = "#{solr_config}"+"/#{extracted_config_dir}"
              # Validate and upload the config contents to ZK
              validate_and_upload_config_jar_contents(extracted_config_dir_full_path, config_name)
              run_reload_collection(node['collection_name'], node['port_num'])

            else
              raise "Noticed changes in the configuration provided. Date provided to upload the zk config doesn't match today's date. So please provide today's date in YYYY-MM-DD format if you're intending to upload/ update a zk config."
            end
          end

        end
      end



      # Remove Extracted custom config files/ directories
      bash 'remove_extracted_configs' do
        code <<-EOH
          cd #{solr_config}/
          sudo rm -rf #{solr_config}/#{extracted_config_dir} on line 386
          sudo rm -rf #{solr_config}/#{config_name}
          sudo rm -rf /tmp/xmldiffs.py

        EOH
        not_if { "#{config_jar}".empty? }
      end
    end

    # Reloads the collection whenever there is a change in the configuration uploaded to ZK

    def run_reload_collection (collection_name, port_number)
      Chef::Log.info("Flag to reload the collection : #{node['allow_auto_reload_collection']}")

      if node['allow_auto_reload_collection'] != "true"
        Chef::Log.info("Skipping reload of collection #{node['collection_name']} since  \"allow_auto_reload_collection\" is not enabled by the user ")
      else
        cluster_collections = get_cluster_collections(node['ipaddress'], port_number)

        if not cluster_collections.empty?
          collection_exists = cluster_collections.include?(collection_name)
        else
          collection_exists = false
        end

        if not collection_exists
          Chef::Log.info("Skipping re-load of collection #{node['collection_name']} since the collection is not yet created.")
        else
          Chef::Log.info("Reloading the collection : #{collection_name}")
          params = {
              :action => "RELOAD",
              :name => collection_name
          }

          reload_response = collection_api(node['ipaddress'], port_number, params)
          Chef::Log.info("Reload is over. #{reload_response}")
        end
      end

    end

    # The method calls the Solr Config REST API, passing in the provided params object as POST data
    # It returns the response object
    def override_solrconfig_api(host_name, port_no, collection_name, params)
      path = "http://#{host_name}:#{port_no}/solr/#{collection_name}/config"
      req_body = params.to_json

      response = http_request_post(host_name, port_no, path, req_body)
      obj = JSON.parse(response.body())

      if response.code == '200'
        puts "Success!!!"
        if obj != nil
          return obj
        else
          puts "URL - #{path}"
          puts "Response : #{response}"
          raise response.msg
        end
      else
        print_and_raise_bad_response(response, path)
      end
    end

    # This method calls the CONFIG API to override the Solr config param values.
    # The props object contains the key value mapping of Solr configuration parameter name and the value to be used
    def override_solrconfig_properties(host_name,port, collection_name, props)

      props.each do |k, v|
        params = {
            "set-property" => { k => v}

        }
        Chef::Log.info("Override solrconfig #{k} with value #{v}");
        override_solrconfig_api(host_name, port, collection_name, params)
      end

    end

    # This method calls the CONFIG API to remove the over-ridden Solr config params.
    # After this parameter is removed the original value from solrconfig.xml or the System property will start taking effect
    # The props object is an array of solr configuration parameter names which needs to be removed from the configoverlay.json file
    def remove_overridden_solrconfig_properties(host_name, port, collection_name, props)

      props.each do |propname|
        params = {
            "unset-property" => propname
        }
        override_solrconfig_api(host_name, port, collection_name, params)

      end

    end

    # This method gets the list of configuration properties which have been overridden and exists in the configoverlay.json file
    # on the zookeeper
    def get_props_from_configoverlay_json(host_name, port_no, collection_name)

      path = "http://#{host_name}:#{port_no}/solr/#{collection_name}/config/overlay?omitHeader=true"

      response = http_request_get(host_name, port_no, path)

      props_overridden = Hash.new

      if response.code == '200'

        obj = JSON.parse(response.body())

        if obj != nil
          props = obj["overlay"]["props"]
          if not props.nil?
              puts "Properties from configoverlay.json #{props}"
              if not props["updateHandler"].nil?
                if not props["updateHandler"]["autoSoftCommit"].nil?
                  if not props["updateHandler"]["autoSoftCommit"]["maxTime"].nil?
                    props_overridden["updateHandler.autoSoftCommit.maxTime"] = props["updateHandler"]["autoSoftCommit"]["maxTime"]
                  end
                end

                if not props["updateHandler"]["autoCommit"].nil?
                  if not props["updateHandler"]["autoCommit"]["maxTime"].nil?
                    props_overridden["updateHandler.autoCommit.maxTime"] = props["updateHandler"]["autoCommit"]["maxTime"]
                  end

                  if not props["updateHandler"]["autoCommit"]["maxDocs"].nil?
                    props_overridden["updateHandler.autoCommit.maxDocs"] = props["updateHandler"]["autoCommit"]["maxDocs"]
                  end
                end
              end

              if not props["query"].nil?
                if not props["query"]["filterCache"].nil? and not props["query"]["filterCache"]["size"].nil?
                  props_overridden["query.filterCache.size"] = props["query"]["filterCache"]["size"]
                end

                if not props["query"]["queryResultCache"].nil? and not props["query"]["queryResultCache"]["size"].nil?
                  props_overridden["query.queryResultCache.size"] = props["query"]["queryResultCache"]["size"]
                end

                if not props["query"]["DocumentCache"].nil? and not props["query"]["DocumentCache"]["size"].nil?
                  props_overridden["query.DocumentCache.size"] = props["query"]["DocumentCache"]["size"]
                end

                if not props["query"]["queryResultMaxDocCached"].nil?
                  props_overridden["query.queryResultMaxDocCached"] = props["query"]["queryResultMaxDocCached"]
                end
              end

          end
          return props_overridden
        else
          puts "URL - #{path}"
          puts "Response : #{response}"
          raise response.msg
        end
      else
        print_and_raise_bad_response(response, path)
      end
    end

    # This metthod performs a diff between the two properties objects and returns a HashMap object
    # containing only the properties which have changed.
    def get_properties_changed(new_props, exising_props)
      props_changed = Hash.new
      new_props.each do |k, v|
        if exising_props[k].nil?
          #new property got added
          props_changed[k] = v
        elsif exising_props[k].to_s != new_props[k].to_s
          props_changed[k] = v
        end
      end
      return props_changed
    end

    # This method uses DOM API and XPath to locate the XML elements in the solrconfig.xml file and update the
    # the target element's content value. It uses the props_map object to determine how to locate the element or the element
    # with a specific attribute. Please take a look at the get_prop_metadata method to understand the structure of the prop_metadata
    # object

    def update_solrconfig_and_override_properties(config_file, props_map, solrconfig_contains_update_processor_chain)
      file = File.new(config_file )
      doc = REXML::Document.new file

      # start processing the props map
      props_map.each do |prop_name, prop_metadata|
        # get the parent element; parent element can contain multiple elements
        parent_elem_array, solrconfig_contains_update_processor_chain = get_parent_element(doc, prop_metadata["parent_elem_path"], prop_metadata["parent_elem_attrs"], prop_metadata["parent_mandatory_children"], solrconfig_contains_update_processor_chain)
        # add the element to parent elements
        add_element(parent_elem_array, prop_metadata["parent_elem_path"], prop_metadata["elem_name"], prop_metadata["elem_val_select"], prop_metadata["attr_name"], prop_metadata["attr_value"], prop_metadata["elem_children"], prop_metadata["add_after_attr_name"], prop_metadata["add_after_attr_value"], prop_metadata["edit_attr_val"], prop_metadata["elem_value"])
      end

      # Write the updated DOM object back to the provided xml file
      config_tmpfile = "#{config_file}.tmp"
      formatter = REXML::Formatters::Pretty.new
      formatter.compact = true
      File.open(config_tmpfile, "w") do |f|
        f.puts formatter.write(doc.root,"")
      end

      # Move the newly created temp config file to solrconfig.xml file
      File.rename "#{config_tmpfile}",  "#{config_file}"

      # create initParams, and add the processor chain created earlier into it, if solrconfig_contains_update_processor_chain is false
      if not solrconfig_contains_update_processor_chain
        props_map_for_init_params = get_props_map_for_init_params()
        update_solrconfig_and_override_properties(config_file, props_map_for_init_params, true)
      end

      return solrconfig_contains_update_processor_chain
    end

    def get_props_map_for_init_params()
      prop_map = {
          "1_search_initparams" => {
              #parent element XPATH, the element under which needs to be changed
              "parent_elem_path" => "config",
              #child element name
              "elem_name"  => "initParams",
              #attribute used to select the correct child element
              "attr_name"  => "path",
              #attribuate value for the child element
              "attr_value" => "/update/**"

          },
          "2_search_initparams_defaults" => {
              "parent_elem_path" => "config/initParams[@path='/update/**']",
              "parent_elem_attrs" => {
                  "path" => "/update/**"
              },
              "elem_name" => "lst",
              "attr_name" => "name",
              "attr_value" => "defaults"
          },
          "3_search_initparams_defaults_updatechain" => {
              "parent_elem_path" => "config/initParams[@path='/update/**']/lst[@name='defaults']",
              "elem_name" => "str",
              "attr_name" => "name",
              "attr_value" => "update.chain",
              "elem_value" => "custom"
          }
      }
      return prop_map
    end

    def check_default_chain_is_set()
      resp = collection_api(node['ipaddress'],node['port_num'], {}, nil, "/solr/"+node['collection_name']+"/config/updateRequestProcessorChain")
      # collect all the processor chain names
      update_processor_chain_names = []
      resp['config']['updateRequestProcessorChain'].each do |processor_chain|
        update_processor_chain_names.push(processor_chain['name'])
      end

      # get the name of default chain defined in the initParams
      resp_init_params = collection_api(node['ipaddress'],node['port_num'], {}, nil, "/solr/"+node['collection_name']+"/config/initParams")
      default_processor_chain_name = String.new
      resp_init_params['config']['initParams'].each do |param|
        if param['path'] =~ /update/ && param['defaults'].key?("update.chain")
          default_processor_chain_name = param['defaults']['update.chain']
          break
        end
      end

      if not update_processor_chain_names.include?(default_processor_chain_name)
        Chef::Log.error("initParams does not contain a default chain from the list of updateRequestProcessorChains that are defined in the solrconfig.xml")
      end
    end

    def get_parent_element(doc, parent_elem_path, elem_attrs, children, solrconfig_contains_update_processor_chain)
      parent_elem_array = []
      doc.elements.each(parent_elem_path) { |element| parent_elem_array.push(element)}
      # return the element if it exists
      if parent_elem_array.length!=0
        #if parent exists then ensure all the parent elements have given attributes
        parent_elem_array.each do |parent|
          if not elem_attrs.nil?
            elem_attrs.each do |attr_name, attr_value|
              if parent.attributes[attr_name].nil?
                parent.attributes[attr_name] = attr_value
              end
            end
          end
        end
        # create the parent element if it does not exist
      else
        index = parent_elem_path.rindex("/")
        if index != -1
          parent_parent_elem_path = parent_elem_path.slice(0, index)
          parent_elem_name = parent_elem_path.slice(index + 1, parent_elem_path.length)
          # remove any attribute value provided  using '@' from xpath so that we consider only the path
          # for ex. in path "config/updateRequestProcessorChain[@name='ignore-commit-from-client']"
          # we want to create node with actual path 'config/updateRequestProcessorChain' as we need only path,
          # otherwise a node will be added as below
          # <updateRequestProcessorChain[@name='ignore-commit-from-client']></updateRequestProcessorChain[@name='ignore-commit-from-client']>
          # we want node to be created as <updateRequestProcessorChain></updateRequestProcessorChain>
          parent_elem_name = parent_elem_name.split('[@')[0]
          # set the variable solarconfig_contains_update_processor_chain as false because solrconfig does not have any updateRequestProcessorChains defined
          if parent_elem_name == "updateRequestProcessorChain"
            solrconfig_contains_update_processor_chain = false
          end
          parent_parent_elem = doc.elements[parent_parent_elem_path]
          parent_elem_array.push(create_element(parent_parent_elem, parent_parent_elem_path, parent_elem_name, elem_attrs, children, nil, nil))
        else
          Chef.log.warn("Unable to create the missing element, Invalid XPATH #{parent_elem_path} provided")
        end

      end
      return parent_elem_array, solrconfig_contains_update_processor_chain
    end

    def add_element(parent_elem_array, parent_elem_path, elem_name, elem_val_select, attr_name, attr_value, children, add_after_attr_name, add_after_att_value, edit_attr_val, elem_value)
      parent_elem_array.each do |parent_elem|
        found = false
        # search in parent element (using elem_name) if the element exists
        element_to_be_added = nil
        parent_elem.elements.to_a.each do |element|
          if element.name == elem_name
            # if allows multiple entries
            if not elem_val_select.nil?
              #  return the element with same text value as in elem_val_select
              if element.text != elem_val_select
                Chef::Log.info("#{element.text} != #{elem_val_select}")
                next
              else
                found = true
                element_to_be_added = element
                break
              end
              # else allows single entry
            else
              #  if attr_name is not nil
              if not attr_name.nil?
                # return the element if it's attribute value matches given attr_value
                Chef::Log.info("elem.attributes[attr_name] - #{element.attributes[attr_name]}, attr_value - #{attr_value}")
                if element.attributes[attr_name] == attr_value
                  # Chef::Log.info("returning elem - attr name is not nil and are equal")
                  found = true
                  element_to_be_added = element
                  break
                else
                  # return the element if edit_attr_value is true
                  if edit_attr_val == "true"
                    found =true
                    element_to_be_added = element
                    break
                  end
                end
                #  else return element
              else
                found = true
                element_to_be_added = element
                break
              end
            end
          end
        end
        # else element does not exist so create one in all the parent elements
        if not found
          if elem_name != ""
            element = create_element(parent_elem, parent_elem_path, elem_name, { attr_name => attr_value }, children, add_after_attr_name, add_after_att_value)
            element_to_be_added = element
          end
        end

        # update the value of the element to be added if elem_value is not nil
        if not element_to_be_added.nil?
          if not elem_value.nil?
            element_to_be_added.text = elem_value
            # else update the attribute value for the element
          else
            attr_value = element_to_be_added.attributes[attr_name]
            Chef::Log.info("exisitng attr val = #{attr_value}")
            element_to_be_added.attributes[attr_name] = attr_value
          end
        end
        #print "result -> ", parent_elem, "\n"
      end
    end

    # this method creates an element, sets its children and adds it to appropriate position in the parent element
    def create_element(parent_elem, parent_elem_path, elem_name, elem_attrs, children, add_after_attr_name, add_after_attr_value)
      # create the element
      elem = REXML::Element.new(elem_name)

      # set the attributes
      if not elem_attrs.nil?
        elem_attrs.each { |attr_name, attr_value| elem.attributes[attr_name] = attr_value }
      end

      # add the element in parent path at appropriate position
      if add_after_attr_name.nil? || add_after_attr_value.nil?
        parent_elem.elements << elem
      else
        position_found = false
        # to add the element as first element provide add_after_attr_name = "" and add_after_attr_value = ""
        if add_after_attr_name == "" && add_after_attr_value == ""
          position_found = true
        end
        parent_elem.elements.to_a.each do |node|
          if position_found
            node.previous_sibling = elem
            break
          end
          if node.attributes[add_after_attr_name] == add_after_attr_value
            position_found = true
          end
        end
      end

      # create the children
      if not children.nil?
        elem_path = parent_elem_path + "/" + elem_name + "[@"
        elem_attrs.each { |attr_name, attr_value|
          elem_path = elem_path + attr_name + "='" + attr_value + "']"
          break
        }
        children.each do |child|
          child_elem = create_element(elem, elem_path, child["elem_name"], { child["attr_name"] => child["attr_value"] }, nil, nil, nil)
          child_elem.text = child["elem_value"]
        end
      end

      # return the element
      return elem
    end

    # The configoverlay feature of Solr which allows you to overlay the configuration changes on top of the solrconfig.xml file
    # is not supported for all the configurations. In order to support changing unsupported configuration options we modify the
    # solrconfig.xml file directly.
    #
    # The below method returns a Map of property metadata objects which is used to locate the XML elements and
    # make changes to the target XML element content. The key is the Solr OneOps configuration attribute
    #
    def get_prop_metadata_for_solrconfig_update()

      solr_custom_params = node['solr_custom_params']
      props_map = {
          "1_updatelog_numrecordstokeep" => {
              #parent element XPATH, the element under which needs to be changed
              "parent_elem_path" => "config/updateHandler/updateLog",
              #child element name
              "elem_name"  => "int",
              #attribute used to select the correct child element
              "attr_name"  => "name",
              #attribuate value for the child element
              "attr_value" => "numRecordsToKeep"

          },
          "2_updatelog_maxnumlogstokeep" => {
              #parent element XPATH, the element under which needs to be changed
              "parent_elem_path" => "config/updateHandler/updateLog",
              #child element name
              "elem_name"  => "int",
              #attribute used to select the correct child element
              "attr_name"  => "name",
              #attribute value for the child element
              "attr_value" => "maxNumLogsToKeep"

          },
          "3_mergepolicyfactory_maxmergeatonce"  => {
              "parent_elem_path" => "config/indexConfig/mergePolicyFactory",
              #attributes to create if the element needs to be created
              "parent_elem_attrs" => {
                  "class" => "org.apache.solr.index.TieredMergePolicyFactory"
              },
              "elem_name"  => "int",
              "attr_name"  => "name",
              "attr_value" => "maxMergeAtOnce"
          },
          "4_mergepolicyfactory_segmentspertier"  => {
              "parent_elem_path" => "config/indexConfig/mergePolicyFactory",
              "parent_elem_attrs" => {
                  "class" => "org.apache.solr.index.TieredMergePolicyFactory"
              },
              "elem_name"  => "int",
              "attr_name"  => "name",
              "attr_value" => "segmentsPerTier"
          },
          "5_rambuffersizemb"  => {
              "parent_elem_path" => "config/indexConfig",
              "elem_name"  => "ramBufferSizeMB"
          },
          "6_maxbuffereddocs"  => {
              "parent_elem_path" => "config/indexConfig",
              "elem_name"  => "maxBufferedDocs"
          },
          "7_request_select_defaults_timeallowed"  => {
                  "parent_elem_path" => "config/requestHandler[@name='/select']/lst[@name='defaults']",
                  #attributes to create if the element needs to be created
                  "parent_elem_attrs" => {
                      "class" => "solr.SearchHandler"
                  },
                  "elem_name"  => "int",
                  "attr_name"  => "name",
                  "attr_value" => "timeAllowed"
          },
          "8_slow_query_threshold_millis" => {
              "parent_elem_path" => "config/query",
              "elem_name"  => "slowQueryThresholdMillis"
          },
          "9_request_parser_add_http_request_to_context" => {
              "parent_elem_path" => "config/requestDispatcher",
              "elem_name"  => "requestParsers",
              "edit_attr_val" => "true",
              "attr_name" => "addHttpRequestToContext",
              "attr_value" => "true"
          },
          "10_solr_custom_comp_lib" => {
              "parent_elem_path" => "config/lib[@regex='solr-custom-components-\\d.*\\.jar']",
              "parent_elem_attrs" => {
                  "dir" => "${solr.install.dir:../../../..}/plugins/",
                  "regex" => "solr-custom-components-\\d.*\\.jar"
              },
              "elem_name"  => ""
          },
          # "11_enable_search_comp_request_select_last_comp_block_expensive"  => {
          #     "parent_elem_path" => "config/requestHandler[@name='/select']",
          #     #attributes to create if the element needs to be created
          #     "parent_elem_attrs" => {
          #         "class" => "solr.SearchHandler"
          #     },
          #     "elem_name"  => "arr",
          #     "attr_name"  => "name",
          #     "attr_value" => "last-components"
          # },
          # "12_enable_search_comp_request_select_block_queries"  => {
          #     "parent_elem_path" => "config/requestHandler[@name='/select']/arr[@name='last-components']",
          #     #attributes to create if the element needs to be created
          #     "parent_elem_attrs" => {
          #         "class" => "solr.SearchHandler"
          #     },
          #     "elem_name"  => "str",
          #     "elem_type"  => "multiple",
          #     "elem_value" => "block-expensive-queries"
          # },
          # "13_enable_search_comp_request_select_slow_query"  => {
          #     "parent_elem_path" => "config/requestHandler[@name='/select']/arr[@name='last-components']",
          #     #attributes to create if the element needs to be created
          #     "parent_elem_attrs" => {
          #         "class" => "solr.SearchHandler"
          #     },
          #     "elem_name"  => "str",
          #     "elem_type"  => "multiple",
          #     "elem_value" => "slow-query-logger"
          # }

      }
      if node["block_expensive_queries"] == "true"
        block_expensive_queries_class = solr_custom_params['block_expensive_queries_class']
        if block_expensive_queries_class == nil || block_expensive_queries_class.empty?
          Chef::Log.error("Option enable block_expensive_queries is selected but block_expensive_queries_class is not provided. To enable block_expensive_queries make sure block_expensive_queries_class, custome artifact & url is provided to solr cloud service.")
        else
          block_expensive_query_props = {
              "11_search_comp_block_expensive_queries" => {
                  "parent_elem_path" => "config/searchComponent[@name='block-expensive-queries']",
                  "parent_elem_attrs" => {
                      "name" => "block-expensive-queries",
                      "class" => block_expensive_queries_class
                  },
                  "elem_name"  => "lst",
                  "attr_name"  => "name",
                  "attr_value" => "defaults"
              },
              "12_search_comp_block_expensive_queries_maxstartoffset" => {
                  "parent_elem_path" => "config/searchComponent[@name='block-expensive-queries']/lst[@name='defaults']",
                  "elem_name"  => "int",
                  "attr_name"  => "name",
                  "attr_value" => "maxStartOffset",
                  "elem_value" => node['max_start_offset_for_expensive_queries']
              },
              "13_search_comp_block_expensve_queries_maxrowsfetch" => {
                  "parent_elem_path" => "config/searchComponent[@name='block-expensive-queries']/lst[@name='defaults']",
                  "elem_name"  => "int",
                  "attr_name"  => "name",
                  "attr_value" => "maxRowsFetch",
                  "elem_value" => node['max_rows_fetch_for_expensive_queries']
              },
              "14_enable_search_comp_request_select_last_comp_block_expensive"  => {
                  "parent_elem_path" => "config/requestHandler[@name='/select']",
                  "elem_name"  => "arr",
                  "attr_name"  => "name",
                  "attr_value" => "last-components"
              },
              "15_enable_search_comp_request_select_block_queries"  => {
                  "parent_elem_path" => "config/requestHandler[@name='/select']/arr[@name='last-components']",
                  "elem_name"  => "str",
                  "elem_type"  => "multiple",
                  "elem_value" => "block-expensive-queries",
                  "elem_val_select" => "block-expensive-queries"
              }
          }

          props_map.merge!(block_expensive_query_props)
        end
      end
      if node["enable_slow_query_logger"] == "true"
        slow_query_logger_class = solr_custom_params['slow_query_logger_class']
        if slow_query_logger_class == nil || slow_query_logger_class.empty?
          Chef::Log.error("Option enable_slow_query_logger is selected but slow_query_logger_class is not provided. To enable enable_slow_query_logger make sure slow_query_logger_class, custome artifact & url is provided to solr cloud service.")
        else
          slow_query_props = {
              "16_search_comp_slow_query_logger" => {
                  "parent_elem_path" => "config/searchComponent[@name='slow-query-logger']",
                  "parent_elem_attrs" => {
                      "name" => "slow-query-logger",
                      "class" => slow_query_logger_class
                  },
                  "elem_name"  => "lst",
                  "attr_name"  => "name",
                  "attr_value" => "defaults"
              },
              "17_search_comp_slow_query_logger_slow_query_threshold" => {
                  "parent_elem_path" => "config/searchComponent[@name='slow-query-logger']/lst[@name='defaults']",
                  "elem_name"  => "int",
                  "attr_name"  => "name",
                  "attr_value" => "slowQueryThresholdMillis",
                  "elem_value" => node["slow_query_threshold_millis"]
              },
              "18_enable_search_comp_request_select_last_comp_slow_query"  => {
                  "parent_elem_path" => "config/requestHandler[@name='/select']",
                  "elem_name"  => "arr",
                  "attr_name"  => "name",
                  "attr_value" => "last-components"
              },
              "19_enable_search_comp_request_select_slow_query"  => {
                  "parent_elem_path" => "config/requestHandler[@name='/select']/arr[@name='last-components']",
                  "elem_name"  => "str",
                  "elem_type"  => "multiple",
                  "elem_value" => "slow-query-logger",
                  "elem_val_select" => "slow-query-logger"
              }
          }
          props_map.merge!(slow_query_props)
        end
      end

      if node["enable_query_source_tracker"] == "true"
           query_source_tracker_class = solr_custom_params['query_source_tracker_class']
           if query_source_tracker_class == nil || query_source_tracker_class.empty?
             Chef::Log.error("Option enable_query_source_tracker is selected but query_source_tracker_class not provided. To enable enable_query_source_tracker make sure query_source_tracker_class, custome artifact & url is provided to solr cloud service.")
           else
              query_source_tracker = {
              "20_search_comp_query_source_tracker" => {
                  "parent_elem_path" => "config/searchComponent[@name='query-source-tracker']",
                  "parent_elem_attrs" => {
                      "name" => "query-source-tracker",
                      "class" => query_source_tracker_class
                  },
                  "elem_name"  => "lst",
                  "attr_name"  => "name",
                  "attr_value" => "queryIdentifiers"
              },
              "21_search_comp_query_source_tracker_failqueries" => {
                  "parent_elem_path" => "config/searchComponent[@name='query-source-tracker']",
                  "elem_name"  => "bool",
                  "attr_name"  => "name",
                  "attr_value" => "failQueries",
                  "elem_value" => node['enable_fail_queries']
              },
              "22_enable_search_comp_request_select_first_comp_source_tracker"  => {
                  "parent_elem_path" => "config/requestHandler[@name='/select']",
                  "elem_name"  => "arr",
                  "attr_name"  => "name",
                  "attr_value" => "first-components"
              },
              "23_enable_search_comp_request_select_source_tracker"  => {
                  "parent_elem_path" => "config/requestHandler[@name='/select']/arr[@name='first-components']",
                  "elem_name"  => "str",
                  "elem_type"  => "multiple",
                  "elem_value" => "query-source-tracker"
              }
          }

          props_map.merge!(query_source_tracker)
        end

        qis = JSON.parse(node['query_identifiers'])
        qis.each do |qi|
          property_dom_for_qi = {
              "parent_elem_path" => "config/searchComponent[@name='query-source-tracker']/lst[@name='queryIdentifiers']",
              "elem_name"  => "str",
              "attr_name"  => "name",
              "attr_value" => "qi",
              "elem_type"  => "multiple",
              "elem_value" => qi,
              "elem_val_select" => qi
          }

          props_map["24_search_comp_query_source_tracker_#{qi}"] = property_dom_for_qi
        end

        # Adding a by default query source tracker param to make the PING command working with a valid qi
        # ping API comes under select requestHandler. Here we are enabling the query source tracker for select requestHandler.
        default_qi = {
            "parent_elem_path" => "config/searchComponent[@name='query-source-tracker']/lst[@name='queryIdentifiers']",
            "elem_name"  => "str",
            "attr_name"  => "name",
            "attr_value" => "qi",
            "elem_type"  => "multiple",
            "elem_value" => "internal_admin",
            "elem_val_select" => "internal_admin"
        }

        props_map["24_search_comp_query_source_tracker_default_qi"] = default_qi

      end

      props_map["25_search_comp_log_delete_update_processor"] = {
          "parent_elem_path" => "config/updateRequestProcessorChain",
          "parent_elem_attrs" => {
              "name" => "custom"
          },
          "parent_mandatory_children" => [
              {
                  "elem_name" => "processor",
                  "attr_name" => "class",
                  "attr_value" => "solr.LogUpdateProcessorFactory"
              },
              {
                  "elem_name" => "processor",
                  "attr_name" => "class",
                  "attr_value" => "solr.DistributedUpdateProcessorFactory"
              },
              {
                  "elem_name" => "processor",
                  "attr_name" => "class",
                  "attr_value" => "solr.RunUpdateProcessorFactory"
              }
          ],
          "elem_name" => "processor",
          "attr_name" => "class",
          "attr_value" => "com.walmart.strati.search.solr.LogDeleteQueryProcessorFactory",
          "add_after_attr_name" => "class",
          "add_after_attr_value" => "solr.DistributedUpdateProcessorFactory",
          "elem_children" => [
              {
                  "elem_name" => "bool",
                  "attr_name" => "name",
                  "attr_value" => "logDeleteQuery",
                  "elem_value" => "true"
              }
          ]
      }

      if not node["updatelog_numrecordstokeep"].nil?
          props_map["1_updatelog_numrecordstokeep"]["elem_value"] = node["updatelog_numrecordstokeep"]
      end

      if not node["mergepolicyfactory_maxmergeatonce"].nil?
        props_map["3_mergepolicyfactory_maxmergeatonce"]["elem_value"] = node["mergepolicyfactory_maxmergeatonce"]
      end

      if not node["mergepolicyfactory_segmentspertier"].nil?
        props_map["4_mergepolicyfactory_segmentspertier"]["elem_value"] = node["mergepolicyfactory_segmentspertier"]
      end

      if not node["rambuffersizemb"].nil?
        props_map["5_rambuffersizemb"]["elem_value"] = node["rambuffersizemb"]
      end

      if not node["maxbuffereddocs"].nil?
        props_map["6_maxbuffereddocs"]["elem_value"] = node["maxbuffereddocs"]
      end

      if not node["updatelog_maxnumlogstokeep"].nil?
        props_map["2_updatelog_maxnumlogstokeep"]["elem_value"] = node["updatelog_maxnumlogstokeep"]
      end

      if not node["request_select_defaults_timeallowed"].nil?
        props_map["7_request_select_defaults_timeallowed"]["elem_value"] = node["request_select_defaults_timeallowed"]
      end

      if not node["slow_query_threshold_millis"].nil?
        props_map["8_slow_query_threshold_millis"]["elem_value"] = node["slow_query_threshold_millis"]
      end

      if node['min_rf'] != nil && !node['min_rf'].empty?
        if node['min_rf'] <= node['replication_factor']
          init_params_props_map = {
            "25_init_params_update_handler" => {
              "parent_elem_path" => "config/initParams[@path='\/update\/**']",
              "parent_elem_attrs" => {
                "path" => "/update/**"
              },
              "elem_name"  => "lst",
              "attr_name"  => "name",
              "attr_value" => "defaults"
            },
            "26_init_params_update_handler_min_rf" => {
              "parent_elem_path" => "config/initParams[@path='/update/**']/lst[@name='defaults']",
              "elem_name"  => "str",
              "attr_name"  => "name",
              "attr_value" => "min_rf",
              "elem_value" => node['min_rf']
            }
          }
        else
          error = "The minimum replication factor(min_rf = #{node['min_rf']}) parameter is greater than the replication factor(replication_factor = #{node['replication_factor']})." +
          "This is not very logical because anything minimum cannot be more than regular."
          puts "***FAULT:FATAL=#{error}"
          raise error
        end
        props_map.merge!(init_params_props_map)
      end

      return props_map.sort
    end

  # This method returns true if each of updateRequestProcessorChain in solrconfig.xml has processor with class 'solr.IgnoreCommitOptimizeUpdateProcessorFactory'
  # to confirm that client requests explicit commit ignored or optimized
  # ex. this verifies that each updateRequestProcessorChain includes a processor definition as below
  # <processor class='solr.IgnoreCommitOptimizeUpdateProcessorFactory'>
  #   <int name='statusCode'>xxx</int>
  # </processor>
  # Below validation is based on sample response for API http://<solr_host>:8983/solr/<collection_name>/config/updateRequestProcessorChain
  # {"config": {
  #     "updateRequestProcessorChain": [
  #       {
  #         "default": "true",
  #         "name": "versionedUpdate",
  #         "": [{"class": "solr.DocBasedVersionConstraintsProcessorFactory"},
  #              {"class": "solr.IgnoreCommitOptimizeUpdateProcessorFactory","statusCode":200},
  #              {"class": "solr.TimestampUpdateProcessorFactory"},
  #              {"class": "solr.RunUpdateProcessorFactory"}
  #             ]
  #       },
  #       {
  #         "name": "add-unknown-fields-to-the-schema",
  #         "": [{"class": "solr.UUIDUpdateProcessorFactory"},
  #              {"class": "solr.ParseDoubleFieldUpdateProcessorFactory"},
  #              {"class": "solr.RunUpdateProcessorFactory"}
  #             ]
  #       }
  #     ]
  #   }
  # }

  # This method returns the status of last backup/restore
  def get_core_backup_restore_status(host,port,core_name,command)
    uri = URI("http://#{host}:#{port}/solr/#{core_name}/replication?command=#{command}&wt=json")
    Chef::Log.info("Backup/Restore status url : #{uri}")
    res = Net::HTTP.get_response(uri)
    if !res.is_a?(Net::HTTPSuccess)
      msg = "Error while getting core backup/restore status using url #{uri} : #{res.message}"
      Chef::Log.error(res.body)
      raise msg
    else
      Chef::Log.info("backup/restore response : #{res.body}")
    end
    restorestatus = JSON.parse(res.body)
    return restorestatus['restorestatus']['status']
  end

  # This method restore given collection core with the given backup_name
  def restore(host,port, collection_name, core_name, backup_location, backup_name)
    uri = URI("http://#{host}:#{port}/solr/#{core_name}/replication?command=restore&location=#{backup_location}&name=#{backup_name}")
    Chef::Log.info("Restore url : #{uri}")
    res = Net::HTTP.get_response(uri)
    if !res.is_a?(Net::HTTPSuccess)
      raise "Error while restoring core #{core_name} using url #{uri} : #{res.message}"
    else
      Chef::Log.info("restore response : #{res.body}")
    end
  end

  # This method returns list of collections
  def get_collections(host,port)
    params = {
        :action => "CLUSTERSTATUS"
    }
    clusterstatus_resp_obj = collection_api(host, port, params)
    return clusterstatus_resp_obj["cluster"]["collections"]
  end

  # This method returns list of shards for given collection
  def get_shards_by_collection(host,port,collection_name)
    collections = get_collections(host,port)
    if collections.empty? || !collections.has_key?(collection_name)
      raise "No collection found : #{collection_name}"
    end
    return collections[collection_name]['shards']
  end

  # This map of [node_ip=>core_name] for given collection & shard
  # ex. {"private_ip1"=>"core_node69"}
  def get_shard_core_ip_to_name_map(host, port, collection_name, shard_name)
    shards = get_shards_by_collection(host,port,collection_name)
    Chef::Log.info("shards : #{shards}")
    replicas = shards[shard_name]['replicas']
    node_ip_to_core_name_map = Hash.new()
    replicas.each do |core_name,core|
      node_name = core['node_name']
      node_ip = node_name.split(':')[0]
      node_ip_to_core_name_map[node_ip] = core_name
    end
    return node_ip_to_core_name_map
  end

  # This method return the map of leader ip & replica_name
  # ex. {"private_ip1":"sams_list1_shard1_replica0","private_ip2":"sams_list1_shard2_replica0"}
  def get_shard_leader_ip_to_name_map(host, port, collection_name, shard_name)
    shards = get_shards_by_collection(host,port,collection_name)
    Chef::Log.info("shards : #{shards.to_json}")
    leaders = shards[shard_name]['replicas'].values.select { |replica| replica['leader'] == 'true'}
    node_ip_to_replica_name_map = Hash.new()
    leaders.each do |leader|
      core_name = leader['core']
      node_name = leader['node_name']
      node_ip = node_name.split(':')[0]
      node_ip_to_replica_name_map[node_ip] = core_name
    end
    return node_ip_to_replica_name_map
  end

  # compares two xml files. If diff is found and error_on_diff = true, then throw error
  def xml_diff(file1, file2, error_on_diff)
    diff_command = "#{node['user']['dir']}/solr_pack/xmldiffs.py  #{file1} #{file2}"
    Chef::Log.info("Executing command : #{diff_command}")
    result = `#{diff_command} 2>&1`
    exit_code = $?
    Chef::Log.info("compare_files exit_code : #{exit_code}")
    if exit_code != 0
      raise "Error while comparing zookeeper config"
    end
    Chef::Log.info("solrconfig.xml diff : #{result}")
    if result != nil && !result.empty?
      msg = "Following differences found in config between the backup #{file1} and current zookeeper. "
      if error_on_diff == true
        raise "#{msg} Please make sure zookeeper config is same as the one present in the backup location #{file1}"
      else
        Chef::Log.info(msg)
      end
    else
      Chef::Log.info("No differences found in config between the backup #{file1} and current zookeeper.")
    end
  end

  # get list of dir names starting with prefix and ends with backup_timestamp+-10 min
  def get_backup_dirs(prefix, backup_location, backup_timestamp)
    input_time = DateTime.strptime(backup_timestamp,"%Y_%m_%d_%H_%M_%S" )
    Chef::Log.info("backup_timestamp : #{input_time}")
    backup_names = []
    Dir.foreach(backup_location) do |backup_dir|
      if backup_dir.start_with?(prefix)
        # Ex. Backup dir name syntax 'snapshot.sams_list1_shard1_replica0_20171116_003001'
        # extract timestamp suffix from the dir name & parse to date object
        stored_backup_date_time = DateTime.strptime(backup_dir.split(//).last(19).join("").to_s,"%Y_%m_%d_%H_%M_%S" )
        Chef::Log.info("stored_backup_date_time : #{stored_backup_date_time}")
        diff_in_minutes = (((input_time - stored_backup_date_time)*24*60*60).to_i)/ 60
        Chef::Log.info("diff_in_minutes : #{diff_in_minutes}")
        if diff_in_minutes.to_i <= 10 && diff_in_minutes.to_i >= -10
          backup_names.push backup_dir
        end
       end
    end
    return backup_names
  end

    # This method returns true if schemaless mode feature is enabled.
    def schemaless_mode_enabled
      # Get the solr config response object through the config API.
      solr_config_response = collection_api(node['ipaddress'],node['port_num'], {}, nil, "/solr/"+node['collection_name']+"/config")

      if solr_config_response['config']['updateRequestProcessorChain'].empty?
        Chef::Log.error("No UpdateRequestProcessorChain found")
        return false
      end

      # Verify if any updateRequestProcessorChains in solrconfig.xml has processor with class 'solr.AddSchemaFieldsUpdateProcessorFactory'
      # Example:
      # <updateProcessor class="solr.processor.SignatureUpdateProcessorFactory" name="signature">
      #  <bool name="enabled">true</bool>
      #  <str name="signatureField">id</str>
      # </updateProcessor>
      # <updateProcessor class="solr.RemoveBlankFieldUpdateProcessorFactory" name="remove_blanks"/>

      # <updateProcessorChain name="add-unknown-fields-to-the-schema" processor="remove_blanks,signature">
      # <processor class="solr.AddSchemaFieldsUpdateProcessorFactory">
      #  <str name="defaultFieldType">strings</str>
      #  <lst name="typeMapping">
      #    <str name="valueClass">java.lang.Boolean</str>
      #    <str name="fieldType">booleans</str>
      #  </lst>
      #  <lst name="typeMapping">
      #    <str name="valueClass">java.util.Date</str>
      #    <str name="fieldType">tdates</str>
      #  </lst>
      # </processor>
      # <processor class="solr.LogUpdateProcessorFactory"/>
      # <processor class="solr.DistributedUpdateProcessorFactory"/>
      # <processor class="solr.RunUpdateProcessorFactory" />
      # </updateProcessorChain>

      # Get updateRequestProcessorChain object from config response object.
      update_req_proc_chain_obj = solr_config_response['config']['updateRequestProcessorChain']
      update_req_proc_chain_obj.each do |processor_chain|
        processor_chain.each do |key, value|
          if key == "processor"
            update_processors = value.split(',')
            update_processor_obj = solr_config_response['config']['updateProcessor']
            update_processor_names = update_processor_obj != nil ? update_processor_obj.keys : []
            update_processor_names.each do |update_processor|
              if update_processors.include?(update_processor) && update_processor_obj[update_processor]["class"] == "solr.AddSchemaFieldsUpdateProcessorFactory"
                return true
              end
            end
          end
          if value.kind_of?(Array)
            value.each do |update_processor|
              if update_processor['class'] == 'solr.AddSchemaFieldsUpdateProcessorFactory'
                return true
              end
            end
          end
        end
      end
      return false
    end

  end
end
