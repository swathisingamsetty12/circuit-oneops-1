# set the proxy if it exists as a cloud var
Utils.set_proxy(node.workorder.payLoad.OO_CLOUD_VARS)

COOKBOOKS_PATH = "/opt/oneops/inductor/circuit-oneops-1/components/cookbooks"

require 'fog/azurerm'
require "#{COOKBOOKS_PATH}/azure_lb/libraries/load_balancer.rb"
require "#{COOKBOOKS_PATH}/azure_lb/libraries/work_order_utils.rb"
require "#{COOKBOOKS_PATH}/azure_base/libraries/utils.rb"
Dir.glob("#{COOKBOOKS_PATH}/azure/libraries/*.rb").each {|lib| require lib}

@work_order_utils = AzureLb::WorkOrder.new(node)

lb_name = @work_order_utils.get_lb_name
resource_group_name = @work_order_utils.get_resource_group_name
azure_creds = @work_order_utils.get_azure_creds

lb_svc = AzureNetwork::LoadBalancer.new(azure_creds)
load_balancer = lb_svc.get(resource_group_name, lb_name)

effective_level = "INFO"
if load_balancer.nil? || (load_balancer.name != lb_name)
  effective_level = "ERROR"
  puts "#{effective_level}: LB: #{lb_name} is not configured in azure\n"
end

#get nics attached to load balancer.
lb_backend_ipconfigs = lb_svc.get_backend_ip_configurations(resource_group_name, lb_name, azure_creds)
lb_backend_ipconfig_ids = lb_backend_ipconfigs.map {|backend_ipconfig| backend_ipconfig.id}


#get nics attached to computes that are listed in workorder. all these nics should be in loadbalancer's backend address pool
vm_svc = AzureCompute::VirtualMachine.new(azure_creds)
nic_svc = AzureNetwork::NetworkInterfaceCard.new(azure_creds)
nic_svc.rg_name = resource_group_name
nics_attchd_computes_from_wo = []

computes_from_wo = @work_order_utils.compute_nodes
computes_from_wo.each do |compute|
  vm = vm_svc.get(resource_group_name, compute[:instance_name])
  nic_name = nic_svc.get_nic_name(vm.network_interface_card_ids[0])
  nic = nic_svc.get(nic_name)
  nics_attchd_computes_from_wo.push(nic)
end

if lb_backend_ipconfig_ids.count != nics_attchd_computes_from_wo.count
  effective_level = "ERROR"
  puts "#{effective_level}: LB: #{lb_name} compute count mapped in azure and oneops doensn't match\n"
end

nics_attchd_computes_from_wo.each do |nic|
  if !lb_backend_ipconfig_ids.include? (nic.ip_configuration_id)
    effective_level = "ERROR"
    puts "#{effective_level}: LB: #{lb_name}\n"
    puts "#{effective_level}: Compute: #{nic.ip_configuration_id}\n"
  end
end

expected_load_distribution = @work_order_utils.load_distribution

load_balancer.load_balancing_rules.each do |lb_rule|
  if !lb_rule.load_distribution.include? (expected_load_distribution)
    effective_level = "ERROR"
    puts "#{effective_level}: LB: #{lb_name} has wrong configuration for load distribution method\n"
  end
end

listeners_from_wo = @work_order_utils.listeners
probes = load_balancer.probes

probes.each do |p|
  listener = listeners_from_wo.detect {|l| l[:iport].to_i == p.port}
  if listener.nil?
    if p.protocol.downcase != 'http'
      effective_level = "ERROR"
      puts "#{effective_level}: LB: #{lb_name} protocol is not set to http\n"
    end
  end
end

probes.each do |p|
  listener = listeners_from_wo.detect {|l| l[:iport].to_i == p.port}
  if !listener.nil? && listener[:iprotocol].downcase == 'https'
    if p.protocol.downcase != 'tcp'
      effective_level = "ERROR"
      puts "#{effective_level}: LB: #{lb_name} protocol is not set to https\n"
    end
  end
end

probes.each do |p|
  listener = listeners_from_wo.detect {|l| l[:iport].to_i == p.port}

  if !listener.nil?
    expected_probe_protocol = 'http'
    if listener[:iprotocol].downcase == 'https' || listener[:iprotocol].downcase == 'tcp'
      expected_probe_protocol = 'tcp'
    end
    if p.protocol.downcase != expected_probe_protocol
      effective_level = "ERROR"
      puts "#{effective_level}: LB: #{lb_name} protocol is set to backend protocol of a matching listener\n"
    end
  end
end

listeners_from_wo.each do |l|
  az_lb_rule = load_balancer.load_balancing_rules.detect {|r| r.frontend_port.to_i == l[:vport].to_i}
  if az_lb_rule.probe_id == nil || az_lb_rule.probe_id.empty?
    effective_level = "ERROR"
    puts "#{effective_level}: LB: #{lb_name} listener does not has a probe attached to it\n"
  end
end

listeners_from_wo.each do |l|
  if l[:iprotocol].downcase == 'http'
    az_lb_rule = load_balancer.load_balancing_rules.detect {|r| r.frontend_port.to_i == l[:vport].to_i}
    az_lb_rule_probe_name = Hash[*(az_lb_rule.probe_id.split('/'))[1..-1]]['probes']
    az_lb_rule_probe = load_balancer.probes.detect {|p| p.name == az_lb_rule_probe_name}

    if az_lb_rule_probe.protocol.downcase != 'http'
      effective_level = "ERROR"
      puts "#{effective_level}: LB: #{lb_name} protocol is not set to http\n"
    end
  end
end

ecvs_from_wo = @work_order_utils.ecvs

#uses any http probe when a probe with same port is not found
listeners_from_wo.each do |l|
  if l[:iprotocol].downcase == 'http'
    ecv = ecvs_from_wo.detect {|ecv| ecv[:port].to_i == l[:iport].to_i}
    if ecv.nil?
      az_lb_rule = load_balancer.load_balancing_rules.detect {|r| r.frontend_port.to_i == l[:vport].to_i}
      az_lb_rule_probe_name = Hash[*(az_lb_rule.probe_id.split('/'))[1..-1]]['probes']
      az_lb_rule_probe = load_balancer.probes.detect {|p| p.name == az_lb_rule_probe_name}

      if az_lb_rule.probe_id == nil || az_lb_rule.probe_id.empty? && az_lb_rule_probe.protocol.downcase != 'http'
        effective_level = "ERROR"
        puts "#{effective_level}: LB: #{lb_name} protocol is not set to http when a probe with same port is not found\n"
      end
    end
  end
end

#tcp listener
listeners_from_wo.each do |l|
  if l[:iprotocol].downcase == 'tcp'
    az_lb_rule = load_balancer.load_balancing_rules.detect {|r| r.frontend_port.to_i == l[:vport].to_i}
    az_lb_rule_probe_name = Hash[*(az_lb_rule.probe_id.split('/'))[1..-1]]['probes']
    az_lb_rule_probe = load_balancer.probes.detect {|p| p.name == az_lb_rule_probe_name}

    if az_lb_rule_probe.protocol.downcase != 'tcp'
      effective_level = "ERROR"
      puts "#{effective_level}: LB: #{lb_name} protocol is not set to tcp\n"
    end
  end
end

listeners_from_wo.each do |l|
  if l[:iprotocol].downcase == 'https'
    az_lb_rule = load_balancer.load_balancing_rules.detect {|r| r.frontend_port.to_i == l[:vport].to_i}
    az_lb_rule_probe_name = Hash[*(az_lb_rule.probe_id.split('/'))[1..-1]]['probes']
    az_lb_rule_probe = load_balancer.probes.detect {|p| p.name == az_lb_rule_probe_name}

    if az_lb_rule_probe.protocol.downcase != 'tcp'
      effective_level = "ERROR"
      puts "#{effective_level}: LB: #{lb_name} protocol is not set to tcp\n"
    end
  end
end


ruby_block 'check status on compute' do
  block do
    probes.each do |p|
      request_path = p.request_path
      protocol = p.protocol

      if protocol.downcase == 'tcp'
        protocol = "https"
      end

      port = p.port
      computes_from_wo.each do |compute|
        vm_ip = compute[:ipaddress]
        comm = "curl -i -k #{protocol}://#{vm_ip}:#{port}#{request_path}"
        Chef::Resource::RubyBlock.send(:include, Chef::Mixin::ShellOut)
        result = shell_out(comm)

        if result.stdout.include? "HTTP/1.1 200"
          effective_level = "INFO"
          puts "#{effective_level}: ECV on #{vm_ip} is returing proper response on port : #{port} and protocol : #{protocol}\n"
        else
          effective_level = "ERROR"
          puts "#{effective_level}: ECV check on #{vm_ip} failed on port : #{port} and protocol : #{protocol}\n"
        end
      end
    end
  end
end


lb_ip = load_balancer.frontend_ip_configurations[0].private_ipaddress

ruby_block 'check status at LB' do
  block do
    listeners_from_wo.each do |l|
      frontend_port = l[:vport]
      protocol = l[:vprotocol]
      backend_port = l[:iport]

      request_path = nil
      if ecvs_from_wo == nil || ecvs_from_wo.empty?
        ecvs_from_wo.each do |ecv|
          if backend_port == ecvs_from_wo[:port]
            request_path = ecvs_from_wo[:request_path]
            break
          end
        end
      end

      comm = "curl -i -k #{protocol}://#{lb_ip}:#{frontend_port}#{request_path}"
      Chef::Resource::RubyBlock.send(:include, Chef::Mixin::ShellOut)
      lb_result = shell_out(comm)

      if lb_result.stdout.include? "HTTP/1.1 200"
        effective_level = "INFO"
        puts "#{effective_level}: LB is routing traffic from port : #{frontend_port} and protocol : #{protocol}\n"
      else
        effective_level = "ERROR"
        puts "#{effective_level}: LB is not routing traffic from port : #{frontend_port} and protocol : #{protocol}\n"
      end
    end
  end
end


if Chef::Log.level == :debug
  Chef::Log.info("level: #{Chef::Log.level}")
  puts "###### Full Detail ######"
  puts load_balancer.inspect
end