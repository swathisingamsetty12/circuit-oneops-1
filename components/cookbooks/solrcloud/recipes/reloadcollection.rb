#
# Cookbook Name :: solrcloud
# Recipe :: reloadcollection.rb
#
# The recipe reloads collection on the solrcloud.
#

include_recipe 'solrcloud::default'

extend SolrCloud::Util

# Wire java util to chef resources.
Chef::Resource::RubyBlock.send(:include, SolrCloud::Util)

args = ::JSON.parse(node.workorder.arglist)
collection_name = args["PhysicalCollectionName"]


reloadCollection(node['solr_collection_url'],"#{collection_name}")

