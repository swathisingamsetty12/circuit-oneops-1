name 'Solrcloud'
license 'All rights reserved'
version '1.0.0'


grouping 'default',
  :access => 'global',
  :packages => ['base', 'mgmt.catalog', 'mgmt.manifest', 'catalog', 'manifest']

grouping 'bom',
  :access => 'global',
  :packages => ['bom']


attribute 'solr_version',
  :description => 'Solr Version',
  :required => 'required',
  :default => '7.2.1',
  :format => {
    :help => 'Select the specific version to set up solrcloud. Be sure the artifact uploaded to mirror repository',
    :category => '1.SolrCloud',
    :form => {'field' => 'select', 'options_for_select' => [
       ['6.4.2 (Deprecated)', '6.4.2'], ['6.6.0 (Deprecated)', '6.6.0'],
       ['7.2.1', '7.2.1'], ['7.3.1 (Not tested yet)', '7.3.1']
    ]},
    :order => 4
  }

# The below 2 attributes are used for auto replace feature. This feature needs to be discussed with the team and finalize and do not want to display to the user in advance.
# attribute 'join_replace_node',
#   :description => "Join replaced node to the cluster",
#   :default => "false",
#   :help => 'Depending on the maxShardsPerNode parameter,this feature chooses the shards which has least no of replicas and adds the replaced node as a replica for the given list of collections.User should replace each node at a time and can verify whether the node join as a replica to the cluster',
#   :format => {
#     :category => '1.SolrCloud',
#     :order => 5,
#     :form => {'field' => 'checkbox'}
#   }

# attribute 'collection_list',
#   :description => "Collection List",
#   :format => {
#     :category => '1.SolrCloud',
#     :filter => {'all' => {'visible' => 'join_replace_node:eq:true'}},
#     :order => 6,
#   }

attribute 'jmx_port',
  :description => 'JMX PortNo',
  :default => '13001',
  :format => {
    :category => '1.SolrCloud',
    :help => 'Specify the port no to listen for remote JMX connections. Be sure that port is free',
    :order => 10
  }

attribute 'installation_dir_path',
  :description => 'Installation Directory',
  :default => '/app',
  :format => {
    :help => 'Installation Directory',
    :category => '1.SolrCloud',
    :filter => {"all" => {"visible" => "solr_version:neq:4.10.3 && solr_version:neq:4.10.3.2"}},
    :order => 11
  }

attribute 'data_dir_path',
  :description => 'Data Directory',
  :default => '/app/solrdata',
  :format => {
    :help => 'data directory',
    :category => '1.SolrCloud',
    :filter => {"all" => {"visible" => "solr_version:neq:4.10.3 && solr_version:neq:4.10.3.2"}},
    :order => 12
  }

attribute 'port_no',
  :description => 'Solr PortNo',
  :default => '8983',
  :format => {
    :help => 'Specify the port no to start the solr process',
    :category => '1.SolrCloud',
    :filter => {"all" => {"visible" => "solr_version:neq:4.10.3 && solr_version:neq:4.10.3.2"}},
    :order => 13
  }

attribute 'gc_tune_params',
  :description => 'GC TUNING',
  :data_type => 'array',
  :default => '',
  :format => {
    :help => 'Defaults here are recommended for powerful machines: 16+ cores, 100+gb RAM. Most of these are not recommended for less powerful machines. Remove +PerfDisableSharedMem to make Solr process visible to tools like jps, jstat etc',
    :category => '1.SolrCloud',
    :filter => {"all" => {"visible" => "solr_version:neq:4.10.3 && solr_version:neq:4.10.3.2"}},
    :order => 14
  }

attribute 'gc_log_params',
  :description => 'GC LOGGING',
  :data_type => 'array',
  :default => '',
  :format => {
    :help => 'Example: -verbose:gc -XX:+PrintHeapAtGC -XX:+PrintGCDetails etc. (One per line)',
    :category => '1.SolrCloud',
    :filter => {"all" => {"visible" => "solr_version:neq:4.10.3 && solr_version:neq:4.10.3.2"}},
    :order => 15
  }

attribute 'solr_opts_params',
  :description => 'SOLR OPTS',
  :data_type => 'array',
  :default => '',
  :format => {
    :help => 'Example: solr.autoSoftCommit.maxTime=3000 etc (One per line. We append -D automatically to each option and pass the same to java command line of the solr process)',
    :category => '1.SolrCloud',
    :filter => {"all" => {"visible" => "solr_version:neq:4.10.3 && solr_version:neq:4.10.3.2"}},
    :order => 16
  }

attribute 'zk_client_timeout',
  :description => 'Zookeeper client timeout (ms)',
  :format => {
    :help => 'The requests to Zookeeper will timeout if it takes longer time than this value for the requests to complete. Please increase this value (zkClientTimeout) if you see requests to Zookeeper timeout.',
    :category => '1.SolrCloud',
    :order => 19
  }
  
attribute 'solr_max_heap',
  :description => 'MAX HEAP',
  :format => {
    :help => 'MAX HEAP SIZE',
    :category => '1.SolrCloud',
    :filter => {"all" => {"visible" => "solr_version:neq:4.10.3 && solr_version:neq:4.10.3.2"}},
    :order => 17
  }

attribute 'solr_min_heap',
  :description => 'MIN HEAP',
  :format => {
    :help => 'MIN HEAP SIZE',
    :category => '1.SolrCloud',
    :filter => {"all" => {"visible" => "solr_version:neq:4.10.3 && solr_version:neq:4.10.3.2"}},
    :order => 18
  }

attribute 'solr_api_timeout_sec',
  :description => 'Solr API Timeout (Sec)',
  :format => {
    :help => 'Timeout in sec. used for api calls during deployment.',
    :category => '1.SolrCloud',
    :order => 19
  }

attribute 'zk_select',
  :description => 'Internal/External',
  :required => 'required',
  :default => 'ExternalEnsemble',
  :format => {
      :help => 'Internal/External',
      :category => '3.Zookeeper',
      :order => 19,
      :form => {'field' => 'select', 'options_for_select' => [['ExternalEnsemble', 'ExternalEnsemble'],['InternalEnsemble-SameAssembly', 'InternalEnsemble-SameAssembly']]}
  }

attribute 'zk_host_fqdns',
  :description => 'Zookeeper FQDN',
  :format => {
      :help => "External Zookeeper cluster FQDN string",
      :category => '3.Zookeeper',
      :filter => {'all' => {"visible" => "zk_select:eq:ExternalEnsemble"}},
      :order => 20
  }

attribute 'platform_name',
  :description => 'Zookeeper Platform',
  :format => {
    :help => 'Add the zookeeper platform to the design and provide the platform name. Be sure to deploy both the solrcloud and zookeeper platforms together.',
    :category => '3.Zookeeper',
    :filter => {'all' => {"visible" => "zk_select:eq:InternalEnsemble-SameAssembly"}},
    :order => 21
  }

attribute 'jolokia_port',
  :description => 'Jolokia PortNo',
  :default => '17330',
  :format => {
    :category => '2.SolrCloud Monitoring',
    :help => 'Specify the jolokia process port no.',
    :order => 25
  }

# Enable this flag to push the Solr Metrics to Medusa using the Rest endpoint - instead of Jolokia
attribute 'enable_medusa_metrics',
  :description => 'Enable Medusa Metrics with Solr APIs',
  :default => "false",
  :format => {
    :category => '2.SolrCloud Monitoring',
    :help => 'Enable the Metrics pushed to Medusa using APIs',
    :form => {'field' => 'checkbox'},
    :order => 27
  }

# Enable this flag to push the Solr JMX Metrics to Medusa by using the Jolokia Http project - instead of Rest endpoint
attribute 'enable_jmx_metrics',
  :description => 'Enable JMX Metrics with Jolokia',
  :default => "true",
  :format => {
    :category => '2.SolrCloud Monitoring',
    :help => 'Enable Solr Monitoring with JMX and Jolokia',
    :form => {'field' => 'checkbox'},
    :order => 28
  }

attribute 'jmx_metrics_level',
  :description => 'CollectionLevel/ClusterLevel',
  :default => 'CollectionLevel',
  :format => {
      :help => 'CollectionLevel metrics are core-metrics aggregated per collection on each node while ClusterLevel metrics are core-metrics aggregated over all collections on a node.',
      :category => '2.SolrCloud Monitoring',
      :order => 29,
      :form => {'field' => 'select', 'options_for_select' => [['CollectionLevel', 'CollectionLevel'],['ClusterLevel', 'ClusterLevel']]},
      :filter => {'all' => {"visible" => "enable_jmx_metrics:eq:true"}}
  }

# Added this field only for development testing purpose. This attribute will be checked against the String 'TEST_PRODUCTION_CLUSTER' whenever developer has to test something in production.
# Included this check when a Cinder is added and a symlink is created from data to Cinder
attribute 'admin_check',
  :description => 'Admin Check',
  :default => 'DO_NOT_EDIT',
  :format => {
    :help => 'This field is only for Development purpose. Do not edit this field in any case.',
    :category => '5.For Developer Use',
    :order => 26
  }

# Added this attribute to avod un-necessary deployments of Solrcloud component
attribute 'skip_solrcloud_comp_execution',
  :description => 'Skip Solrcloud component',
  :default => "false",
  :format => {
    :category => '5.For Developer Use',
    :help => 'Select this option when you want to skip the the Solrcloud component deployment. You may want to skip it when the computes are replaced or added.',
    :form => {'field' => 'checkbox'},
    :order => 33
  }

attribute 'graphite_servers',
  :description => "Graphite Servers",
  :data_type => 'array',
  :default => '[]',
  :format => {
      :help => 'Enter a list of graphite servers. ex. graphite.server.com:2003',
      :category => '2.SolrCloud Monitoring',
      :order => 30
  }

attribute 'graphite_prefix',
  :description => "Graphite Metrics Prefix",
  :default => '',
  :format => {
      :help => 'Enter a  graphite metrics prefix',
      :category => '2.SolrCloud Monitoring',
      :order => 31
  }

attribute 'graphite_logfiles_path',
  :description => 'Metrics Tool Logfiles Path',
  :required => 'required',
  :default => '/opt/solr/log/metrics-tool.log',
  :format => {
      :help => 'Directory for metrics tool logs',
      :category => '2.SolrCloud Monitoring',
      :order => 32
  }

# Search Custom Component Specific Attributes
attribute 'solr_custom_component_version',
          :description => 'Solr Custom Components Version',
          :required => 'required',
          :format => {
              :help => 'Enter Version number example: 0.0.1, 0.0.1-SNAPSHOT',
              :category => '7.Solr Custom Component',
              :order => 33
          }

# Solr Monitor Specific Attributes
attribute 'solr_monitor_version',
          :description => 'Version of jar file with Solr Metrics',
          :default => '1.0.5',
          :required => 'required',
          :format => {
              :help => 'Expects a version of a jar file whose artifact is com.walmart.strati.af.df.managed_solr.solrmonitor:solrcloud-oneops-metrics. Example: 0.0.1, 1.0.2 etc',
              :category => '2.SolrCloud Monitoring',
              :order => 34
          }

# Attribute visible only in the Operations phase because of grouping-type bom
# Value for the attribute is assigned by us in the recipes
# This attribute helps to see the IP address in the Operations phase.
# It is used during the compute replace to get the old IPAddress and later its being set with the new compute IP.
attribute 'nodeip',
  :description => 'IPAddress',
  :default => "",
  :grouping => 'bom',
  :format => {
      :important => true,
      :help => 'Node IPAddress (used during replace)',
      :category => '4.Other',
      :order => 22
  }

attribute 'node_solr_version',
  :description => 'solr version',
  :grouping => 'bom',
  :format => {
      :important => true,
      :help => 'Current installed solr version',
      :category => '4.Other',
      :order => 23
  }

attribute 'node_solr_portnum',
  :description => 'solr portno',
  :grouping => 'bom',
  :format => {
      :important => true,
      :help => 'Port number on which the solr is currently running',
      :category => '4.Other',
      :order => 24
  }


attribute 'fault_domain',
  :description => 'Fault Domain',
  :grouping => 'bom',
  :format => {
    :important => true,
    :category => '4.Other',
    :order => 25
  }

attribute 'update_domain',
  :description => 'Update Domain',
  :grouping => 'bom',
  :format => {
    :important => true,
    :category => '4.Other',
    :order => 26
  }

attribute 'url_max_requests_per_sec_map',
  :description => "Url pattern and maxRequestsPerSec for them in DoSFilter",
  :default => "{}",
  :data_type => "hash",
  :format => {
      :help => 'Every URL-pattern (ex. /collection_name/*) and its maxRequestsPerSec (ex. 50) is added as a DoS filter in jetty.xml and can be used for rate-limiting.',
      :category => '6.Jetty parameters',
      :order => 1
  }

# jetty_filter_url attribute is not used as it is moved to solr-service. Cannot remove this because oneops metedata expects it to be there in metedata.
attribute 'jetty_filter_url',
  :description => 'Repository URL of the custom DoS filter',
  :format => {
    :category => '6.Jetty parameters',
    :filter => {'all' => {'visible' => 'false'}},
    :help => 'Repository URL of the jar containing custom DoS filter. Example: http://central.maven.org/maven2/org/eclipse/jetty/solr/solr-jetty-servlets/0.0.1/solr-jetty-servlets-0.0.1.jar',
    :order => 2
  }

attribute 'enable_authentication',
          :description => 'Enable authentication to Solr servers?',
          :default => "false",
          :format => {
              :category => '7.Solr Authentication',
              :help => 'This will enable authentication for Solr server if set to true',
              :form => {'field' => 'checkbox'},
              :order => 1
          }

attribute 'solr_user_name',
          :description => 'Solr App user',
          :format => {
              :help => 'The Solr user name the application will use to connect to Solr server',
              :category => '7.Solr Authentication',
              :filter => {'all' => {'visible' => 'enable_authentication:eq:true'}},
              :order => 2
          }

attribute 'solr_user_password',
          :description => 'Solr App user password',
          :encrypted => true,
          :format => {
              :help => 'The Solr user password the application will use to connect to Solr server',
              :category => '7.Solr Authentication',
              :filter => {'all' => {'visible' => 'enable_authentication:eq:true'}},
              :order => 3
          }

attribute 'enable_cinder',
  :description => 'Enable block-storage for indexes if storage and volume components are added?',
  :default => "true",
  :format => {
    :category => '8.Cinder',
    :help => 'Setting this to false would make Solr NOT use block-storage even if the storage and volume components are added',
    :form => {'field' => 'checkbox'},
    :order => 1
  }

attribute 'allow_ephemeral_on_azure',
  :description => 'Allow ephemeral on Azure',
  :default => "false",
  :format => {
    :category => '8.Cinder',
    :help => 'Setting this to false will enfore to use storage instead of ephemeral',
    :form => {'field' => 'checkbox'},
    :order => 2
  }
######################################
# Actions in the Operations Phase    #
# Each recipe here becomes an action #
######################################

recipe "addreplica",
  :description => 'Add Replica To Collection',
  :args => {
    "PhysicalCollectionName" => {
      "name" => "PhysicalCollectionName",
      "description" => "Add the selected node as replica to the given collection",
      "required" => true,
      "dataType" => "string"
    },
    "ShardName" => {
      "name" => "ShardName",
      "description" => "Provide shard name to which the node should be added as a replica",
      "required" => true,
      "dataType" => "string"
    }
  }

recipe "status", "Solr JVM Process Status"
recipe "start", "Start Solr JVM Process"
recipe "stop", "Stop Solr JVM Process"
recipe "restart", "Restart Solr JVM Process"

recipe "uploadsolrconfig",
  :description => 'Upload solr config to zookeeper',
  :args => {
    "custom_config_nexus_path" => {
      "name" => "custom_config_nexus_path",
      "description" => "Provide a url to a solr configuration jar.",
      "required" => true,
      "dataType" => "string"
    },
    "config_name" => {
      "name" => "config_name",
      "description" => "Provide a configuration name to upload to zookeeper",
      "required" => true,
      "dataType" => "string"
    }
  }

recipe "medusametrics",
  :description => 'Create COLLECTION_LIST & CORE_LIST oneops env variables and assign the values',
  :args => {
    "collections" => {
      "name" => "collections",
      "description" => "Give the collection list comma seperatedly",
      "required" => true
    }
  }

