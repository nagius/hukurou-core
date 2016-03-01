# Hukurou - Another monitoring tool, the modern way.
# Copyleft 2015 - Nicolas AGIUS <nicolas.agius@lps-it.fr>
#
################################################################################
#
# This file is part of Hukurou.
#
# Hukurou is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
################################################################################

require 'yaml'
require 'optparse'
require 'singleton'

module Hukurou
	module Core
		class Config
			include Singleton
			
			attr_reader :config

			def initialize
				# Default configuration file
				@config_file = "/etc/hukurou/config.yml"

				# Default configuration
				@config = {
					:api => {
						:listen => "0.0.0.0",
						:port => 1664,
					},
					:core => {
						:listen => "0.0.0.0",
						:port => 1664,
						:pool_size => 20,
					},
					:redis => {
						:host => "127.0.0.1"
					},
					:services => {
						:definitions => "/etc/hukurou/services.yml",
						:timeout => 30,  	# 30 seconds
						:max_age => 900		# 15 minutes	
					},
					:assets => "/etc/hukurou/assets",
					:debug => false,
				}

				@mandatory = [:secret]
			end

			def self.load
				instance.load_config
			end

			def self.[](key)
				instance.config[key]
			end

			def load_config
				# Initialize CLI's option structure
				options = { :api => {} }

				# Read CLI options
				OptionParser.new do |opts|
					opts.banner = "Usage: #{$0} [options]"

					opts.on("-d", "--debug", "Turn on debug output") do |d|
						options[:debug] = d
					end

					opts.on("-c", "--config-file FILENAME", "Specify a config file", String) do |file|
						@config_file = file
					end

					opts.on("-l", "--listen IP", "API listen ip", String) do |ip|
						options[:api][:listen] = ip
					end

					opts.on("-p", "--port NUM", "API listen port", Integer) do |port|
						options[:api][:port] = port
					end
				end.parse!

				# Load configuration file
				begin
					@config.deep_merge!(YAML.load_file(@config_file))
				rescue StandardError => e
					abort "Cannot load config file #{@config_file}: #{e}"
				end

				# Override configuration file with command line options
				@config.deep_merge!(options)

				# Check mandatory options
				@mandatory.each { |option|
					if not @config.has_key?(option)
						abort "Missing parameter :shared_secret in config file"
					end
				}

				# Setup logger 
				# Logging to a file and handle rotation is a bad habit. Instead, stream to STDOUT and let the system manage logs.
				# http://www.mikeperham.com/2014/09/22/dont-daemonize-your-daemons/
				
				# Enable debugging mode
				$CELLULOID_DEBUG = @config[:debug]
			end
		end
	end
end

# vim: ts=4:sw=4:ai:noet
