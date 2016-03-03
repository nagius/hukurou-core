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

require 'angelo'

module Hukurou
	module Core
		class Router < Angelo::Base
			content_type :json
			report_errors!

			# Allow CORS queries
			headers "Access-Control-Allow-Origin" => "*" 

			# Allow all HTTP verbs for all CORS preflight queries
			options '*' do
				headers "Access-Control-Allow-Methods" => "POST, GET, PUT, DELETE, OPTIONS"
				headers "Access-Control-Allow-Headers" => "Content-Type"
				halt 200
			end

			# Helpers
			# #######

			# Stop processing if a parameter is missing in the query
			#
			# @param keys [Array<String>] List of parameters
			def validate!(keys)	
				keys.each do |param|
					halt 400, { :message => "Parameter #{param} is missing." } unless params.has_key? param
				end
			end
				
			# Route to manage devices
			# #######################

			# Get services configuration for the device
			get '/config/:device' do
				begin
					{ 
						:id => params["device"],
						:services => Celluloid::Actor[:assets].get_services(params["device"])
					}
				rescue Assets::SubstitutionError => e
					halt 500, { :message => "Configuration error: #{e}" }
				end
			end

			# List devices 
			get '/devices' do 
				Celluloid::Actor[:redis].get_devices()
			end	

			# Get the device states
			get '/devices/:device' do
				device = params["device"]

				if Celluloid::Actor[:redis].device_exists?(device)
					{ 
						:id => params["device"],
						:services => Celluloid::Actor[:redis].get_states(device)
					}
				else
					halt 404, { :message => "Device not found" }
				end
			end

			# Delete a device
			delete '/devices/:device' do 
				device = params["device"]

				if Celluloid::Actor[:redis].device_exists?(device)
					Celluloid::Actor[:redis].delete_device(device)
					halt 204
				else
					halt 404, { :message => "Device not found" }
				end
			end

			# Register a new device
			post '/devices/:device' do 
				device = params["device"]

				if Celluloid::Actor[:redis].device_exists?(device)
					halt 204
				else
					Celluloid::Actor[:redis].add_device(device)
					halt 201
				end
			end

			# Routes to manage states
			# #######################

			# Get a list of faulty services
			get '/states/faulty' do
				services = Hash.new([])
				
				Celluloid::Actor[:redis].get_faulty_services().each { |device, service|
					# Convert nested Array to Hash with Array 
					services[device] += [service]
				}

				services
			end

			# Get state of a specific device and service
			get '/states/:device/:service' do 
				state = Celluloid::Actor[:redis].get_state(params["device"], params["service"])
				halt 404, { :message => "Device or service not found" } if state.nil?
				
				state
			end

			# Save state for a device's service
			post '/states/:device/:service' do 
				validate!(%w[device service state message])

				Celluloid::Actor[:redis].set_state(params["device"], params["service"], params['state'], params['message'])
				halt 201
			end

			# Acknowledge an alert
			post '/states/:device/:service/ack' do
				validate!(%w[device service message user])

				Celluloid::Actor[:redis].ack_state(params["device"], params["service"], params['message'], params['user'])
				halt 201
			end

			# Routes to manage groups and directories
			# #######################################

			# Get the content of the given directory 
			get '/dir/*' do
				path = params['splat'][0].split('/').reject(&:empty?)

				begin
					Celluloid::Actor[:assets].get_sub_dir(path)
				rescue Assets::PathNotFoundError
					halt 404, { :message => "Path not found" }
				end
			end

			# Get the list of devices in this directory
			get '/group/*' do
				path = params['splat'][0].split('/').reject(&:empty?)

				begin
					devices = Celluloid::Actor[:assets].get_devices_by_path(path)
					devices.map { |device|
						{ 
							:id => device, 
							:services => Celluloid::Actor[:redis].get_states(device)
						}
					}
				rescue Assets::PathNotFoundError
					halt 404, { :message => "Path not found" }
				end
			end

			# Get the tree of the directory structure
			get '/tree' do
				Celluloid::Actor[:assets].get_directory_tree
			end

			# Routes to manage mutes
			# ######################
			
			# Create a new maintenance
			post '/mutes' do
				validate!(%w[devices services start end message user])
				
				# Validate params that need to be arrays
				%w[devices services].each { |param|
					if not params[param].is_a?(Array) or params[param].empty?
						halt 400, { :message => "Parameter #{param} must be a non empty array" }
					end
				}

				# Convert times to timestamps
				begin
					starts_at = Time.parse(params['start'])
					ends_at = Time.parse(params['end'])
				rescue ArgumentError => e
					halt 400, { :message => "Wrong time format: #{e}" }
				end
				
				Celluloid::Actor[:redis].set_mute(params['devices'], params['services'], params['message'], params['user'], starts_at, ends_at)
				halt 201
			end

			# Get the list of all mutes
			get '/mutes' do
				Celluloid::Actor[:redis].get_mutes
			end

			# Get a specific mute
			get '/mutes/:id' do
				id = params["id"].to_i

				Celluloid::Actor[:redis].get_mute(id)
			end

			# Delete a mute
			delete '/mutes/:id' do 
				id = params["id"].to_i

				Celluloid::Actor[:redis].delete_mute(id)
				halt 204
			end
		end

		class API
			include Celluloid
			include Celluloid::Internals::Logger
			finalizer :shutdown

			def initialize
				Router.log_level ::Logger::DEBUG if $CELLULOID_DEBUG
			end

			def shutdown
				info "[API] Stopping web server."
				@server.shutdown
			rescue StandardError => e
				debug "[API] Finalizer crashed: #{e}"
			end

			def start
				info "[API] Starting web server."
				@server = Router.run(Config[:api][:listen], Config[:api][:port])
			end
		end
	end
end

# vim: ts=4:sw=4:ai:noet
