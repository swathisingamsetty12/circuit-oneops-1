# wmt:
# d1-pricing.glb.dev.walmart.com
# oo:
# env-assembly-platform.glb.dev.walmart.com
#

env_name = node.workorder.payLoad.Environment[0]["ciName"]
assembly_name = node.workorder.payLoad.Assembly[0]["ciName"]
platform_name = node.workorder.box.ciName

cloud_name = node[:workorder][:cloud][:ciName]
gdns = node[:workorder][:services][:gdns][cloud_name][:ciAttributes]
base_domain = gdns[:gslb_base_domain]

if base_domain.nil? || base_domain.empty?
    msg = "#{cloud_name} gdns cloud service has empty gslb_base_domain"
    Chef::Log.error(msg)
    puts "***FAULT:FATAL=#{msg}"
    e = Exception.new("no backtrace")
    e.set_backtrace("")
    raise e
end

node.set["gslb_base_domain"] = base_domain

# user selected composite of assmb, env, org
subdomain = node.workorder.payLoad.Environment[0]["ciAttributes"]["subdomain"]

gslb_domain = [platform_name, subdomain, base_domain].join(".")
if subdomain.empty?
    gslb_domain = [platform_name, base_domain].join(".")
end
node.set["gslb_domain"] = gslb_domain.downcase

gslb_config_entry = Array.new
full_aliases = Array.new
gslb_config_delete = Array.new
old_full_aliases = Array.new

session_persistance = false
lb = node.workorder.payLoad.lb.first
if lb['ciAttributes']['stickiness'] == 'true'
    session_persistance = true
end

if node.workorder.rfcCi.ciAttributes.has_key?("full_aliases")
    if node.workorder.rfcCi.ciAttributes.full_aliases =~ /\*/ && !is_wildcard_enabled(node)
        fail_with_fault "unsupported use of wildcard functinality for this organization"
    end
    begin
        full_aliases = JSON.parse(node.workorder.rfcCi.ciAttributes.full_aliases)
    rescue Exception =>e
        Chef::Log.info("could not parse full_aliases json: "+node.workorder.rfcCi.ciAttributes.full_aliases)
    end
end

if node.workorder.rfcCi.ciBaseAttributes.has_key?("full_aliases")
    if node.workorder.rfcCi.ciBaseAttributes.full_aliases =~ /\*/ && !is_wildcard_enabled(node)
        fail_with_fault "unsupported use of wildcard functinality for this organization"
    end
    begin
        old_full_aliases = JSON.parse(node.workorder.rfcCi.ciBaseAttributes.full_aliases)
    rescue Exception =>e
        Chef::Log.info("could not parse full_aliases json: "+node.workorder.rfcCi.ciBaseAttributes.full_aliases)
    end
end

gslb_config_entry.push(gslb_domain.downcase)

if !full_aliases.nil?
    if session_persistance
        full_aliases.each do |full|
            Chef::Log.info("full alias dns_name to add to gslb config: #{full}")
            gslb_config_entry.push(full)
        end
    else
        full_aliases.each do |full|
            Chef::Log.info("full alias dns_name to remove from gslb config: #{full}")
            gslb_config_delete.push(full)
        end
    end
end


if !old_full_aliases.nil?
    old_full_aliases.each do |full|
        Chef::Log.info("full alias dns_name for unbind: #{full}")
        gslb_config_delete.push(full)
    end
end

node.set["gslb_config_entry"] = gslb_config_entry
node.set["gslb_config_delete"] = gslb_config_delete