#!/usr/bin/env ruby

require 'eventmachine'
require 'yaml'
require 'optparse'
require 'logger'
require_relative 'lib/monkey_patchs'
require_relative 'lib/em-twistedlike'
require_relative 'lib/network'
require_relative 'lib/database'
require_relative 'lib/assets'
require_relative 'lib/workers'
require_relative 'lib/logs'
require_relative 'lib/api'


def load_config
    # Default configuration
    config_file = "config/config.yml"
    $CFG = {
        :api => {
			:listen => "0.0.0.0",
			:port => 9292,
		},
		:core => {
			:iface => "eth0",
			:port => 1664
		},
        :debug => false,
		:assets => "/etc/hukurou/assets",
		:services => "/etc/hukurou/services.yml"
    }

    # Read CLI options
    options = { :api => {} }
    OptionParser.new do |opts|
        opts.banner = "Usage: #{$0} [options]"

        opts.on("-d", "--debug", "Turn on debug output") do |d|
            options[:debug] = d
        end

        opts.on("-c", "--config-file FILENAME", "Specify a config file", String) do |file|
            config_file = file
        end

        opts.on("-l", "--listen IP", "Listen ip", String) do |ip|
            options[:api][:listen] = ip
        end

        opts.on("-p", "--port NUM", "Listen port", Integer) do |port|
            options[:api][:port] = port
        end
    end.parse!

    # Load configuration file
    begin
        $CFG.deep_merge!(YAML.load_file(config_file))
    rescue StandardError => e
        abort "Cannot load config file #{config_file}: #{e}"
    end

    # Override configuration file with command line options
    $CFG.deep_merge!(options)

	# Check mandatory options
	if not $CFG.has_key?(:dc)
		abort "Missing parameter :dc in config file"
	end

	if not $CFG.has_key?(:database)
		abort "Missing parameter :dc in config file"
	else
		if not $CFG[:database].has_key?(:keyspace)
			abort "Missing parameter database::keyspace in config file"
		end
		if not $CFG[:database].has_key?(:hosts)
			abort "Missing parameter database::hosts in config file"
		else
			if $CFG[:database][:hosts].class != Array
				abort "Parameter database::hosts must be an array of IP"
			end
		end
	end

	if not $CFG.has_key?(:shared_secret)
		abort "Missing parameter :shared_secret in config file"
	end

end


def start()
	db=Database.new
	assets=Assets.new
	workers=Workers.new(db, assets)

	EM.run do
		network = NetworkHandler.get_instance()
		network.on_node_change { |nodes| workers.rebalance(nodes) }
		network.on_device_change { |device, action|
			case action
				when :add
					assets.add_device(device)
					workers.add_device(device)
				when :delete
					assets.remove_device(device)
					workers.remove_device(device)
					db.delete_device(device) 
				else
					$log.error "[CORE] Unknown device change action: #{action}"
			end
		}

		# TODO: factorize that
		d=db.get_devices()
		d.add_callback { |devices|
			assets.expand_tree(devices)
		}
		d.add_errback { |reason|
			$log.error "[CORE] Failed to get list of devices: #{reason}"
			reason.backtrace.each { |trace|
				$log.debug "\t #{trace}"
			}
			EM.stop
		}

		d=network.join_cluster()
		d.add_callback { |members|
			$log.info "[CORE] Cluster joined with members: #{members}"

			dispatch = Rack::Builder.app do
				map '/api/v1/' do
					run Api.new(db, assets, workers, network)
				end
			end

			Rack::Server.start({
				app: dispatch,
				server: 'thin',
				Host: $CFG[:api][:listen],
				Port: $CFG[:api][:port],
				signals: false
			})

			# Setup exit on signal
			exit_handler = Proc.new {
				# Use add_timer to avoid trap conflict with Ruby 2.0
				# https://github.com/eventmachine/eventmachine/issues/418
				EM.add_timer(0) {
					$log.info "[CORE] Exitting..."
					workers.stop_all_workers()
					network.leave_cluster()
					EM.stop 
				}
			}

			Signal.trap("INT", exit_handler)
			Signal.trap("TERM", exit_handler)
			Signal.trap("HUP") {
				EM.add_timer(0) {
					assets.reload()
					d=db.get_devices()
					d.add_callback { |devices|
						assets.expand_tree(devices)
					}
					d.add_errback { |reason|
						$log.error "[CORE] Failed to get list of devices: #{reason}"
						reason.backtrace.each { |trace|
							$log.debug "\t #{trace}"
						}
						EM.stop
					}
				}
			}
		}
		d.add_errback { |reason|
			$log.error "[CORE] Failed to join cluster: #{reason}"
			reason.backtrace.each { |trace|
				$log.debug "\t #{trace}"
			}
			EM.stop
		}
	end
end

load_config

# Setup logger 
# Logging to a file and handle rotation is a bad habit. Instead, stream to STDOUT and let the system manage logs.
$log = Logger.new STDOUT
$log.formatter = CustomFormatter.new
$log.level = $CFG[:debug] ? Logger::DEBUG : Logger::INFO

# Start main loop
begin
	$log.info "[CORE] Starting application..."
	start
rescue StandardError => e
	if $CFG[:debug]
		STDERR.puts e.backtrace.join("\n\t")
	end
	abort "Failed to start application: #{e}"
end


# vim: ts=4:sw=4:ai:noet
