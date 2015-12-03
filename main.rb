#!/usr/bin/env ruby

require 'celluloid/current'
require 'yaml'
require 'optparse'
require_relative 'lib/monkey_patchs'
require_relative 'lib/network'
require_relative 'lib/database'
require_relative 'lib/assets'
require_relative 'lib/workers'
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
	if not $CFG.has_key?(:shared_secret)
		abort "Missing parameter :shared_secret in config file"
	end

end


load_config

# Setup logger 
# Logging to a file and handle rotation is a bad habit. Instead, stream to STDOUT and let the system manage logs.
$CELLULOID_DEBUG = $CFG[:debug]

class Supervisor <  Celluloid::Supervision::Container
	supervise type: Database,	as: :redis
	supervise type: Assets, 	as: :assets
	supervise type: Workers,	as: :workers
	supervise type: Network, 	as: :net
	supervise type: API,	 	as: :api
end

trap "HUP" do
	# FIXME: this doesn't work
	Celluloid::Actor[:assets].async.reload()
end

# Start main loop
Celluloid.logger.info "[CORE] Starting application..."
Supervisor.run

# vim: ts=4:sw=4:ai:noet
