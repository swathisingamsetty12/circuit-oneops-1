#
#
# Pack Name:: solrcloud
#
#

include_pack "genericlb"

name "solrcloud"
description "SolrCloud"
category "Search Engine"
type    'Platform'

platform :attributes => {
                "autoreplace" => "true",
                "replace_after_minutes" => 60,
                "replace_after_repairs" => 3
        }

environment "single", {}
environment "redundant", {}

variable "jolokia_port",
  :description => 'Jolokia Port',
  :value => '17330'

variable "solr_jmx_port",
  :description => 'Solr JMX Port Number',
  :value => '13001'


resource "lb",
  :except => [ 'single' ],
  :cookbook => "oneops.1.lb",
  :attributes => {
    "listeners" => "[\"tcp 8983 tcp 8983\"]"
  }


##########################################################################################
#
# 'ulimit' : The max number of open files allowed for processes runnning as this user. This has to be set as the 'nofile' 
# parameter configured at the compute component level does not increase the limit for the "app" user.
#
############################################################################################

resource 'user-app',
  :cookbook => 'oneops.1.user',
  :design => true,
  :requires => {'constraint' => '1..1'},
  :attributes => {
    'username' => 'app',
    'description' => 'App-User',
    'home_directory' => '/app/',
    'system_account' => true,
    'sudoer' => true,
    'ulimit' => '200000'
  }

resource "java",
  :cookbook => "oneops.1.java",
  :design => true,
  :requires => {
    :constraint => "1..1",
    :services => '*mirror',
    :help => "Java Programming Language Environment"
  },
  :attributes => {
    :jrejdk => "jdk",
    :version => "8",
    :sysdefault => "true",
    :flavor => "oracle"
  }

resource "artifact-app",
  :cookbook => "oneops.1.artifact",
  :design => true,
  :requires => { "constraint" => "0..*" },
  :attributes => { }

resource 'volume-app',
  :cookbook => "oneops.1.volume",
  :requires => {'constraint' => '1..1', 'services' => 'compute'},
  :attributes => {'mount_point' => '/app/',
    'size' => '100%FREE',
    'device' => '',
    'fstype' => 'ext4',
    'options' => ''
}

#########################################################################################
# The compute resource is added to this pack only to set the default values for some
# recommended system parameters in limits.conf and sysctl.conf files on the compute nodes
#
# Note that packs/base.rb also sets some of these options.
# And we need to add our options in addition to those.
# So whenver they change, we might need to change as well.
# This is brittle but there does not seem to be any good option as of now.
#
#
#
# Brief description of limits.conf parameters that we set
#
# 'nofile' : The maximum number of files that can be opened by the root user
#
# 'nproc': The maximum number of processes that can be created on the system. This parameter
# is required to get around the "OutOfMemoryError: Unable to create new native thread" exception in Solr.
# See https://blog.fastthread.io/2016/07/06/troubleshoot-outofmemoryerror-unable-to-create-new-native-thread/ for details.
#
# 'memlock': The maximum locked-in-memory address space (KB)
#
# 'as' : The address space limit
#
#
# Brief description of sysctl.conf file parametes that we set
# 'vm.max_map_count' : The maximum number of mmap files that a process can perform
##############################################################################################

resource "os",
   :cookbook => "oneops.1.os",
   :attributes => {
      'limits' => '{ "nofile" : "200000", "nproc"  : "32768", "memlock" : "unlimited", "as" : "unlimited" }',
      'sysctl' => '{"vm.max_map_count":"131072", "net.ipv4.tcp_mem":"1529280 2039040 3058560", "net.ipv4.udp_mem":"1529280 2039040 3058560", "fs.file-max":"1611021"}'
  }


###################################################################################################
# Thresholds format:
#     Threshold-Name => threshold (
#                           'Sampling-Interval','Aggregation-Operation','Metric-To-Watch',
#                           trigger ('Trigger-Condition', Trigger-Threshold, Duration, Number-Of-Occurences),
#                           reset   ('Reset-Condition',   Reset-Threshold,   Duration, Number-Of-Occurences)
#                       )
#  Example:
#     'HeapMemoryUsage' => threshold(
#                            '1m', 'avg', 'percentUsed',
#                            trigger('>=', 80, 2, 5),
#                            reset  ('<',  75, 2, 3)
#                        )
#  The above example means that we have a threshold called HeapMemoryUsage which tracks the 1 minute
#  average of the metric called percentUsed.
#  This threshold is triggered when the metric matches or goes above "80%" in a "2 minute" duration "5 times"
#  And this threshold is reset when the metric goes below "75%" in a "2 minute" duration "3 times"
#  Note the quoted phrases above. They correspond to the actual values in the above example.
#
#  You can edit these metrics in the transition phase
#  And you can see them running in the operations phase
###################################################################################################
resource "solrcloud",
  :cookbook => "oneops.1.solrcloud",
  :design => true,
  :requires => { "constraint" => "1..1","services" => "maven,mirror,solr-service,compute"},
  :attributes => {
    'jmx_port' => '$OO_LOCAL{solr_jmx_port}',
    'jolokia_port' => '$OO_LOCAL{jolokia_port}',
    'solr_version' => '7.2.1',
    'gc_log_params' => '',
    'zk_client_timeout' => '60000',
    'enable_jmx_metrics' => 'true',
    'solr_max_heap' => '-Xmx20g',
    'solr_min_heap' => '-Xms20g',
    # G1ReservePercent: Reserve memory to keep free so as to reduce the risk of to-space overflows.
    #     The default is 10 percent and is recommended to increase if gc.log file shows too many "to-space exhausted" messages
    # MaxNewSize: Capping this to a maximum of 4G instead of the "unlimited" default ensures that GC does not
    #     have to work on a very large chunk of memory and take long pauses. Promotions from the young
    #     generation happen more frequently, consume lesser time and do not burden the next generation
    'gc_tune_params' => '["+UseG1GC", "MaxGCPauseMillis=250", "ConcGCThreads=4", "ParallelGCThreads=8", "+UseLargePages", "+AggressiveOpts", "+PerfDisableSharedMem", "+ParallelRefProcEnabled", "InitiatingHeapOccupancyPercent=50", "G1ReservePercent=18", "MaxNewSize=4G", "PrintFLSStatistics=1", "+PrintPromotionFailure", "+HeapDumpOnOutOfMemoryError", "HeapDumpPath=/app/solrdata/logs/heapdump"]',
    'solr_opts_params' => '["solr.autoSoftCommit.maxTime=15000", "solr.autoCommit.maxTime=60000", "solr.directoryFactory=solr.MMapDirectoryFactory", "socketTimeout=30000", "connTimeout=30000", "maxConnectionsPerHost=100", "distribUpdateSoTimeout=60000", "distribUpdateConnTimeout=40000", "solr.jetty.threads.max=3000"]',
    'skip_solrcloud_comp_execution' => 'false',
    'enable_cinder' => 'true',
    'solr_custom_component_version' => '0.0.3',
    'solr_api_timeout_sec' => '300',
    'solr_monitor_version' => '1.0.5'
  },

  :monitors => {
    'solrprocess' => {
      :enable => 'true',
      :description => 'SolrProcess',
      :source => '',
      :chart => {'min' => '0', 'unit' => ''},
      :cmd => 'check_solr_process!:::node.port_no:::',
      :cmd_line => '/opt/nagios/libexec/check_solr_process.rb "$ARG1$"',
      :metrics => {
        'up' => metric(:unit => '%', :description => 'Percent Up')
      },
      :thresholds => {
        'SolrProcessDown' => threshold('1m', 'avg', 'up', trigger('<=', 98, 10, 5), reset('>', 95, 2, 1), 'unhealthy')
      }
    },
    'SolrZKConnectionCheck' => {
      :description => 'SolrZKConnection',
      :source => '',
      :chart => {'min' => '0', 'max' => '100', 'unit' => 'Percent'},
      :cmd => 'check_solr_zk_connection',
      :cmd_line => '/opt/nagios/libexec/check_solr_zk_conn.sh',
      :metrics => {
        'up' => metric(:unit => '%', :description => 'Percent Up')
      },
      :thresholds => {
        # Trigger alarm if value goes below 75 for 8 times in a 10 minute window
        # Reset alarm if value goes above 75 for 1 time in a 2 minute window
        'SolrZKConnectionDown' => threshold('1m', 'avg', 'up', trigger('<=', 75, 10, 8), reset('>', 75, 2, 1))
      }
    },
    'SolrMetricsMonitorCheck' => {
        :description => 'SolrMetricsMonitoring',
        :source => '',
        :chart => {'min' => '0', 'max' => '100', 'unit' => 'Percent'},
        :cmd => 'check_solr_metrics_monitor',
        :cmd_line => '/opt/nagios/libexec/check_solr_metrics_monitor.sh',
        :metrics => {
            'up' => metric(:unit => '%', :description => 'Percent Up')
        },
        :thresholds => {
            # Trigger alarm if value goes below 75 for 8 times in a 10 minute window
            # # Reset alarm if value goes above 75 for 1 time in a 2 minute window
            'SolrMetricsMonitoringDown' => threshold('1m', 'avg', 'up', trigger('<=', 75, 10, 8), reset('>', 75, 2, 1))
        }
    },
    'MemoryStats' =>  {
      :description => 'MemoryStats',
      :source => '',
      :chart => {'min'=>0, 'unit'=>''},
      :cmd => 'check_solr_mbeanstat!#{cmd_options[:monitor]}!:::node.port_no:::',
      :cmd_line => '/opt/nagios/libexec/check_solr_mbeanstat.rb $ARG1$ $ARG2$',
      :cmd_options => {
        'monitor' => 'MemoryStats'
      },
      :metrics =>  {
        'freeMemory'   => metric( :unit => 'B', :description => 'Free Memory', :dstype => 'GAUGE'),
        'totalMemory'   => metric( :unit => 'B', :description => 'Total Memory', :dstype => 'GAUGE'),
        'percentUsed' => metric( :unit => '%', :description => 'Percent Memory Used', :dstype => 'GAUGE')
      }
    },
    'ReplicaStatus' =>  {
      :description => 'ReplicaStatus',
      :source => '',
      :chart => {'min'=>0, 'unit'=>''},
      :cmd => 'check_solr_mbeanstat!#{cmd_options[:monitor]}!:::node.port_no:::',
      :cmd_line => '/opt/nagios/libexec/check_solr_mbeanstat.rb $ARG1$ $ARG2$',
      :cmd_options => {
        'monitor' => 'ReplicaStatus'
      },
      :metrics =>  {
        'pctgActiveReplicas'   => metric( :unit => '%', :description => 'ActiveReplicas'),
        'pctgRecoveringReplicas'   => metric( :unit => '%', :description => 'RecoveringReplicas'),
        'pctgDownReplicas'   => metric( :unit => '%', :description => 'DownReplicas'),
        'pctgFailedReplicas'   => metric( :unit => '%', :description => 'FailedReplicas')
      },
      :thresholds => {
          'ReplicaDown' => threshold('1m','avg','pctgDownReplicas',trigger('>=',50,10,9),reset('<',50,10,9))
      }
    },
    'JVMThreadCount' =>  {
      :description => 'JVMThreadCount',
      :source => '',
      :chart => {'min'=>0, 'unit'=>''},
      :cmd => 'check_solr_mbeanstat!#{cmd_options[:monitor]}!:::node.workorder.rfcCi.ciAttributes.jolokia_port:::',
      :cmd_line => '/opt/nagios/libexec/check_solr_mbeanstat.rb $ARG1$ $ARG2$',
      :cmd_options => {
        'monitor' => 'JVMThreadCount'
      },
      :metrics =>  {
        'threadCount'   => metric( :unit => 'B', :description => 'ActiveThreadCount')
      },
      :thresholds => {
      }
    },
    'HeapMemoryUsage' =>  {
      :description => 'HeapMemoryUsage',
      :source => '',
      :chart => {'min'=>0, 'unit'=>''},
      :cmd => 'check_solr_mbeanstat!#{cmd_options[:monitor]}!:::node.workorder.rfcCi.ciAttributes.jolokia_port:::',
      :cmd_line => '/opt/nagios/libexec/check_solr_mbeanstat.rb $ARG1$ $ARG2$',
      :cmd_options => {
        'monitor' => 'HeapMemoryUsage'
      },
      :metrics =>  {
        'heapMemoryUsed'   => metric( :unit => 'B', :description => 'HeapMemoryUsed'),
        'percentUsed'   => metric( :unit => '%', :description => 'PercentUsed')
      }
    }
  },
  :payloads => {
    'CloudPayload' => {
    'description' => 'Clouds',
    'definition' => '{
      "returnObject": false,
      "returnRelation": false,
      "relationName": "base.RealizedAs",
      "direction": "to",
      "targetClassName": "manifest.oneops.1.Solrcloud",
      "relations": [{ "returnObject": false,
        "returnRelation": false,
        "relationName": "manifest.Requires",
        "direction": "to",
        "targetClassName": "manifest.Platform",
        "relations": [{ "returnObject": true,
          "returnRelation": false,
          "returnRelationAttributes":true,
          "relationAttrs":[{
              "attributeName":"adminstatus",
              "condition":"eq", "avalue":"active"
            }],
          "relationName": "base.Consumes",
          "direction": "from",
          "targetClassName": "account.Cloud"
        }]
      }]
    }'
  },
    'SolrClouds' => {
      'description' => 'Solrcloud payload with all its instances',
      'definition' => '{
        "returnObject": false,
        "returnRelation": false,
        "relationName": "base.RealizedAs",
        "direction": "to",
        "targetClassName": "manifest.oneops.1.Solrcloud",
        "relations": [
          {
            "returnObject": true,
            "returnRelation": false,
            "relationName": "base.RealizedAs",
            "direction": "from",
            "targetClassName": "bom.oneops.1.Solrcloud"
          }
        ]
      }'
    }
  }
       
resource "secgroup",
  :cookbook => "oneops.1.secgroup",
  :design => true,
  :attributes => {
    "inbound" => '[ "22 22 tcp 0.0.0.0/0","8080 8080 tcp 0.0.0.0/0","8983 8983 tcp 0.0.0.0/0","13000 14000 tcp 0.0.0.0/0" ]'
  },
  :requires => {
    :constraint => "1..1",
    :services => "compute"
  }

resource "tomcat-daemon",
  :cookbook => "oneops.1.daemon",
  :design => true,
  :requires => {
    :constraint => "0..1",
    :help => "Restarts Tomcat"
  },
  :attributes => {
    :service_name => 'tomcat7',
    :use_script_status => 'true',
    :pattern => ''
  },
  :monitors => {
    'tomcatprocess' => {
      :description => 'TomcatProcess',
      :source => '',
      :chart => {'min' => '0', 'max' => '100', 'unit' => 'Percent'},
      :cmd => 'check_process!:::node.workorder.rfcCi.ciAttributes.service_name:::!:::node.workorder.rfcCi.ciAttributes.use_script_status:::!:::node.workorder.rfcCi.ciAttributes.pattern:::',
      :cmd_line => '/opt/nagios/libexec/check_process.sh "$ARG1$" "$ARG2$" "$ARG3$"',
      :metrics => {
        'up' => metric(:unit => '%', :description => 'Percent Up'),
      },
      :thresholds => {
        'TomcatDaemonProcessDown' => threshold('1m', 'avg', 'up', trigger('<=', 98, 1, 1), reset('>', 95, 1, 1))
      }
    }
  }

resource "tomcat",
  :cookbook => "oneops.1.tomcat",
  :design => true,
  :requires => {
    :constraint => "0..*",
    :services => "mirror"
  },
  :attributes => {
    'install_type' => 'binary',
    'mirrors' => '["$OO_CLOUD{satproxy}/mirrored-assets/apache.mirrors.pair.com/" ]',
    'tomcat_install_dir' => '/app',
    'webapp_install_dir' => '/app/tomcat7/webapps',
    'tomcat_user' => 'app',
    'tomcat_group' => 'app'
  },
  :monitors => {
    'HttpValue' => {
      :description => 'HttpValue',
      :source => '',
      :chart => {'min' => 0, 'unit' => ''},
      :cmd => 'check_http_value!#{cmd_options[:url]}!#{cmd_options[:format]}',
      :cmd_line => '/opt/nagios/libexec/check_http_value.rb $ARG1$ $ARG2$',
      :cmd_options => {
        'url' => '',
        'format' => ''
      },
      :metrics => {
        'value' => metric( :unit => '',  :description => 'value', :dstype => 'DERIVE')
      }
    },
    'Log' => {
      :description => 'Log',
      :source => '',
      :chart => {'min' => 0, 'unit' => ''},
      :cmd => 'check_logfiles!logtomcat!#{cmd_options[:logfile]}!#{cmd_options[:warningpattern]}!#{cmd_options[:criticalpattern]}',
      :cmd_line => '/opt/nagios/libexec/check_logfiles   --noprotocol --tag=$ARG1$ --logfile=$ARG2$ --warningpattern="$ARG3$" --criticalpattern="$ARG4$"',
      :cmd_options => {
        'logfile' => '/log/apache-tomcat/catalina.out',
        'warningpattern' => 'WARNING',
        'criticalpattern' => 'CRITICAL'
      },
      :metrics => {
        'logtomcat_lines' => metric(:unit => 'lines', :description => 'Scanned Lines', :dstype => 'GAUGE'),
        'logtomcat_warnings' => metric(:unit => 'warnings', :description => 'Warnings', :dstype => 'GAUGE'),
        'logtomcat_criticals' => metric(:unit => 'criticals', :description => 'Criticals', :dstype => 'GAUGE'),
        'logtomcat_unknowns' => metric(:unit => 'unknowns', :description => 'Unknowns', :dstype => 'GAUGE')
      },
      :thresholds => {
        'CriticalLogException' => threshold('15m', 'avg', 'logtomcat_criticals', trigger('>=', 1, 15, 1), reset('<', 1, 15, 1)),
      }
    },    
    'JvmInfo' =>  {
      :description => 'JvmInfo',
      :source => '',
      :chart => {'min'=>0, 'unit'=>''},
      :cmd => 'check_tomcat_jvm',
      :cmd_line => '/opt/nagios/libexec/check_tomcat.rb JvmInfo',
      :metrics =>  {
        'max' => metric( :unit => 'B', :description => 'Max Allowed', :dstype => 'GAUGE'),
        'free' => metric( :unit => 'B', :description => 'Free', :dstype => 'GAUGE'),
        'total' => metric( :unit => 'B', :description => 'Allocated', :dstype => 'GAUGE'),
        'percentUsed'  => metric( :unit => 'Percent', :description => 'Percent Memory Used', :dstype => 'GAUGE'),
      },
      :thresholds => {
        'HighMemUse' => threshold('5m','avg','percentUsed',trigger('>',98,15,1),reset('<',98,5,1)),
      }
    },
    'ThreadInfo' =>  {
      :description => 'ThreadInfo',
      :source => '',
      :chart => {'min'=>0, 'unit'=>''},
      :cmd => 'check_tomcat_thread',
      :cmd_line => '/opt/nagios/libexec/check_tomcat.rb ThreadInfo',
      :metrics =>  {
        'currentThreadsBusy'   => metric( :unit => '', :description => 'Busy Threads', :dstype => 'GAUGE'),
        'maxThreads'   => metric( :unit => '', :description => 'Maximum Threads', :dstype => 'GAUGE'),
        'currentThreadCount'   => metric( :unit => '', :description => 'Ready Threads', :dstype => 'GAUGE'),
        'percentBusy'    => metric( :unit => 'Percent', :description => 'Percent Busy Threads', :dstype => 'GAUGE'),
      },
      :thresholds => {
        'HighThreadUse' => threshold('5m','avg','percentBusy',trigger('>',90,5,1),reset('<',90,5,1)),
      }
    },
    'RequestInfo' =>  {
      :description => 'RequestInfo',
      :source => '',
      :chart => { 'min'=>0, 'unit'=>'' },
      :cmd => 'check_tomcat_request',
      :cmd_line => '/opt/nagios/libexec/check_tomcat.rb RequestInfo',
      :metrics =>  {
        'bytesSent'   => metric( :unit => 'B/sec', :description => 'Traffic Out /sec', :dstype => 'DERIVE'),
        'bytesReceived'   => metric( :unit => 'B/sec', :description => 'Traffic In /sec', :dstype => 'DERIVE'),
        'requestCount'   => metric( :unit => 'reqs /sec', :description => 'Requests /sec', :dstype => 'DERIVE'),
        'errorCount'   => metric( :unit => 'errors /sec', :description => 'Errors /sec', :dstype => 'DERIVE'),
        'maxTime'   => metric( :unit => 'ms', :description => 'Max Time', :dstype => 'GAUGE'),
        'processingTime'   => metric( :unit => 'ms', :description => 'Processing Time /sec', :dstype => 'DERIVE')                                                          
      },
      :thresholds => { }
    }
  }

resource "library",
  :cookbook => "oneops.1.library",
  :design => true,
  :requires => { "constraint" => "1..*" },
  :attributes => {
    "packages"  => '["bc"]'
  }

resource "hostname",
  :cookbook => "oneops.1.fqdn",
  :design => true,
  :requires => {
    :constraint => "1..1",
    :services => "dns",
    :help => "optional hostname dns entry"
  }

resource "jolokia_proxy",
  :cookbook => "oneops.1.jolokia_proxy",
  :design => true,
  :requires => {
    "constraint" => "0..1",
    :services => "mirror"
  },
  :attributes => {
    :bind_port => '$OO_LOCAL{jolokia_port}',
    :jvm_parameters => '-Xms512m -Xmx1g'
  },
  :monitors => {
    'JolokiaProxyProcess' => {
      :description => 'JolokiaProxyProcess',
      :source => '',
      :chart => {'min' => '0', 'max' => '100', 'unit' => 'Percent'},
      :cmd => 'check_process!jolokia_proxy!true!/app/metrics_collector/pid/jetty.pid',
      :cmd_line => '/opt/nagios/libexec/check_process.sh "$ARG1$" "$ARG2$" "$ARG3$"',
      :metrics => {
        'up' => metric(:unit => '%', :description => 'Percent Up'),
      },
      :thresholds => {
        'JolokiaProxyProcessDown' => threshold('1m', 'avg', 'up', trigger('<=', 98, 1, 1), reset('>', 95, 1, 1))
      }
    }
  }

resource "telegraf",
  :cookbook => "oneops.1.telegraf",
  :design => true,
  :requires => {
    "constraint" => "0..1",
    :services => "mirror"
  },
  :attributes => {
    'version' => "1.0.0",
    'enable_agent' => 'true',
    'configure' =>''
  },
  :monitors => {
    'telegrafprocess' => {
      :description => 'TelegrafProcess',
      :source => '',
      :enable => 'true',
      :chart => {'min' => '0', 'max' => '100', 'unit' => 'Percent'},
      :cmd => 'check_process_count!telegraf',
      :cmd_line => '/opt/nagios/libexec/check_process_count.sh "$ARG1$"',
      :metrics => {
        'count' => metric(:unit => '', :description => 'Running Process'),
      },
      :thresholds => {
        'TelegrafProcessLow' => threshold('1m', 'avg', 'count', trigger('<', 1, 1, 1), reset('>=', 1, 1, 1)),
        'TelegrafProcessHigh' => threshold('1m', 'avg', 'count', trigger('>=', 200, 1, 1), reset('<', 200, 1, 1))
      }
    }
  }

resource "solr-collection",
  :cookbook => "oneops.1.solr-collection",
  :design => true,
  :requires => { "constraint" => "0..*",
                  "services" => "solr-service,compute"
               },
  :attributes => {
     'date_safety_check_for_config_update' => '1900-01-01',
     'autocommit_maxtime' => '300000',
     'autocommit_maxdocs' => '-1',
     'autosoftcommit_maxtime' => '30000',
     'updatelog_numrecordstoKeep' => '50000',
     'updatelog_maxnumlogstokeep' => '10',
     'mergepolicyfactory_maxmergeatonce' => '10',
     'mergepolicyfactory_segmentspertier' => '10',
     'filtercache_size' => '128',
     'queryresultcache_size' => '128',
     'rambuffersizemb' => '120',
     'maxbuffereddocs' => '10000',
     'request_select_defaults_timeallowed' => '20000',
     'validation_enabled' => 'true',
     'slow_query_threshold_millis' => '1000',
     'collections_for_node_sharing' => '["NO_OP_BY_DEFAULT"]',
     'backup_enabled' => false,
     'backup_cron' => '0 0 * * *',
     'backup_location' => '/app/solr_backup',
     'backup_number_to_keep' => '2'
  },

  :payloads => {

    'Clouds' => {
      'description' => 'Clouds',
      'definition' => '{
        "returnObject": false,
        "returnRelation": false,
        "relationName": "base.RealizedAs",
        "direction": "to",
        "targetClassName": "manifest.oneops.1.Solr-collection",
        "relations": [{ "returnObject": false,
          "returnRelation": false,
          "relationName": "manifest.Requires",
          "direction": "to",
          "targetClassName": "manifest.Platform",
          "relations": [{ "returnObject": true,
            "returnRelation": false,
            "relationAttrs":[{
              "attributeName":"adminstatus",
              "condition":"eq", "avalue":"active"
            }],
            "relationName": "base.Consumes",
            "direction": "from",
            "targetClassName": "account.Cloud"
          }]
        }]
      }'
    },
    # Including the payload for solrcloud in solr-collections so that the metadata attributes in solrcloud will be available in solr-collections component
    # Eg: solr_version from solrcloud metadata is required in solr_collections
    'SolrCloudPayload' => {
      'description' => 'SolrCloudPayload',
      'definition' => '{
        "returnObject": false,
        "returnRelation": false,
        "relationName": "base.RealizedAs",
        "direction": "to",
        "targetClassName": "manifest.oneops.1.Solr-collection",
        "relations": [
         { "returnObject": false,
           "returnRelation": false,
           "relationName": "manifest.Requires",
           "direction": "to",
           "targetClassName": "manifest.Platform",
           "relations": [
             { "returnObject": true,
               "returnRelation": false,
               "relationName": "manifest.Requires",
               "direction": "from",
               "targetClassName": "manifest.oneops.1.Solrcloud"
             }
           ]
         }
       ]
      }'
    },
  'computes' => {
         'description' => 'Computes for Solr-collection',
         'definition' => '{
             "returnObject": false,
             "returnRelation": false,
             "relationName": "base.RealizedAs",
             "direction": "to",
             "targetClassName": "manifest.oneops.1.Solr-collection",
             "relations": [
                 {
                     "returnObject": false,
                     "returnRelation": false,
                     "relationName": "manifest.ManagedVia",
                     "direction": "from",
                     "targetClassName": "manifest.Compute",
                     "relations": [
                         {
                             "returnObject": true,
                             "returnRelation": false,
                             "relationName": "base.RealizedAs",
                             "direction": "from",
                             "targetClassName": "bom.oneops.1.Compute"
                          }
                      ]
                  }
              ]
         }'
     }
  },
  :monitors => {
    'ShardStatus' =>  {
      :description => 'ShardStatus',
      :source => '',
      :chart => {'min'=>0, 'unit'=>''},
      :cmd => 'check_shardstatus.rb!#{cmd_options[:monitor]}!:::node.workorder.rfcCi.ciAttributes.collection_name:::!#{cmd_options[:minReplicas]}',
      :cmd_line => '/opt/nagios/libexec/check_shardstatus.rb $ARG1$ $ARG2$ $ARG3$',
      :cmd_options => {
        'monitor' => 'ShardStatus',
        'minReplicas' => 2
      },
      :metrics =>  {
        'pctgShardsWithMinActiveReplicas' => metric( :unit => '%', :description => 'Percentage of shards with Min Active Replicas', :dstype => 'GAUGE'),
        'pctgShardsUp' => metric( :unit => '%', :description => 'Percentage of Shards UP', :dstype => 'GAUGE')
      },
      :thresholds => {
        'pctgShardsWithMinActiveReplicas' => threshold('1m','avg','pctgShardsWithMinActiveReplicas',trigger('<',100,5,4),reset('=',100,2,1))
      }
    },
    'ReplicaDistributionStatus' =>  {
      :description => 'ReplicaDistributionStatus',
      :source => '',
      :chart => {'min'=>0, 'unit'=>''},
      :cmd => 'replica_distribution_validation.rb!:::node.workorder.rfcCi.ciAttributes.collection_name:::!:::node.workorder.rfcCi.ciAttributes.replication_factor:::',
      :cmd_line => '/opt/nagios/libexec/replica_distribution_validation.rb $ARG1$ $ARG2$',
      :metrics =>  {
        'replicaCountToMove' => metric( :unit => '%', :description => 'No. of Replicas To Move', :dstype => 'GAUGE')
      },
      :thresholds => {
        'replicaCountToMove' => threshold('5m','avg','replicaCountToMove',trigger('>',0,15,2),reset('<=',0,15,1))
      }
    }
  }

# the storage component is for Cinder (or the equivalent in Azure or other cloud providers) - persistent block storage
# Storage component is added to the base pack already. We are just overriding the default values of attributes here
resource "storage",
         :cookbook => "oneops.1.storage",
         :design => true,
         :attributes => {"size" => '10G', "slice_count" => '1'},
         :requires => {"constraint" => "0..1", "services" => "storage"}

# the volume component is for Cinder (or the equivalent in Azure or other cloud providers) - persistent block storage
resource "volume-blockstorage",
         :cookbook => "oneops.1.volume",
         :design => true,
         :requires => {"constraint" => "0..1", "services" => "compute,storage"},
         # Mount point - The mount point to host the cinder blockstorage
         # size - percentage of free disk space
         # fstype - file system type created for the Linux machines
         :attributes => {
             :mount_point => '/blockstorage',
             :size => '100%FREE',
             :device => '',
             :fstype => 'ext4',
             :options => ''
         },
         :monitors => {
             'usage' => {
                 'description' => 'Usage',
                 'chart' => {'min' => 0, 'unit' => 'Percent used'},
                 'cmd' => 'check_disk_use!:::node.workorder.rfcCi.ciAttributes.mount_point:::',
                 'cmd_line' => '/opt/nagios/libexec/check_disk_use.sh $ARG1$',
                 'metrics' => {
                     'space_used' => metric(:unit => '%', :description => 'Disk Space Percent Used'),
                     'inode_used' => metric(:unit => '%', :description => 'Disk Inode Percent Used')
                 },
                 :thresholds => {
                     'LowDiskSpace' => threshold('1m', 'avg', 'space_used', trigger('>=', 90, 5, 2), reset('<', 85, 5, 1)),
                     'LowDiskInode' => threshold('1m', 'avg', 'inode_used', trigger('>=', 90, 5, 2), reset('<', 85, 5, 1))
                 }
             }
         }



# depends_on
[
  {:from => 'user-app', :to => 'os'},
  {:from => 'user-app', :to => 'volume-app'},
  {:from => 'tomcat-daemon', :to => 'tomcat'},
  {:from => 'java', :to => 'os'},
  {:from => 'java', :to => 'compute'},
  {:from => 'solrcloud', :to => 'user-app'},
  {:from => 'artifact-app', :to => 'volume-app'},
  {:from => 'volume-app', :to => 'os'},
  {:from => 'volume-app', :to => 'compute'},
  {:from => 'solrcloud', :to => 'tomcat'},
  {:from => 'solrcloud', :to => 'tomcat-daemon'},
  {:from => 'tomcat', :to => 'java'},
  {:from => 'hostname', :to => 'os'},
  {:from => 'jolokia_proxy', :to => 'solrcloud'},
  {:from => 'user-app', :to => 'volume-blockstorage'},
  {:from => 'solrcloud', :to => 'volume-app'}, # solrcloud need access to mount point from volume-app
  {:from => 'solrcloud', :to => 'volume-blockstorage'},
  {:from => 'volume-blockstorage', :to => 'storage'},
  {:from => 'storage', :to => 'compute'},
  {:from => 'storage', :to => 'os'},
  {:from => 'telegraf', :to => 'solrcloud'},
  {:from => 'solr-collection', :to => 'solrcloud'}
 ].each do |link|
  relation "#{link[:from]}::depends_on::#{link[:to]}",
           :relation_name => 'DependsOn',
           :from_resource => link[:from],
           :to_resource => link[:to],
           :attributes => {"flex" => false, "min" => 1, "max" => 1}
end

relation "solrcloud::depends_on::tomcat",
          :relation_name => 'DependsOn',
          :from_resource => 'solrcloud',
          :to_resource => 'tomcat',
          :attributes => {"propagate_to" => "from", "flex" => false, "min" => 1, "max" => 1}

# managed_via
  [ 'solr-collection','telegraf','jolokia_proxy','tomcat','tomcat-daemon','solrcloud', 'file','user-app', 'java', 'volume-app', 'artifact-app', 'storage', 'volume-blockstorage'].each do |from|
  relation "#{from}::managed_via::compute",
    :except => [ '_default' ],
    :relation_name => 'ManagedVia',
    :from_resource => from,
    :to_resource   => 'compute',
    :attributes    => { }
end
