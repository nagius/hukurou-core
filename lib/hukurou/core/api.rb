
require 'angelo'

module Angelo
	class Base
		module DSL
			def headers hdr
				Responder.default_headers = Responder.default_headers.merge hdr
			end
		end
	end
end

module Hukurou
	module Core
		class Router < Angelo::Base
			content_type :json
			headers "Access-Control-Allow-Origin" => "*"
			report_errors!

			def validate!(keys)	
				keys.each do |param|
					halt 400, "Parameter '#{param}' missing." unless params.has_key? param
				end
			end
				
			# List devices 
			get '/devices' do 
				Celluloid::Actor[:redis].get_devices()
			end	

			# Get checks definition for the device
			get '/device/:device/config' do
				begin
					Celluloid::Actor[:assets].get_services(params["device"])
				rescue Assets::SubstitutionError => e
					halt 500, "Configuration error: #{e}"
				end
			end

			# Get the device states
			get '/states/:device' do
				device = params["device"]

				if Celluloid::Actor[:redis].device_exists?(device)
					Celluloid::Actor[:redis].get_states(device)
				else
					halt 404, "Device not found"
				end
			end

			# Get a list of faulty services
			get '/services/faulty' do
				services = Hash.new([])
				
				Celluloid::Actor[:redis].get_faulty_services().each { |device, service|
					# Convert nested Array to Hash with Array 
					services[device] += [service]
				}

				services
			end

			# Get check results for specific device
			get '/state/:device/:service' do 
				state = Celluloid::Actor[:redis].get_state(params["device"], params["service"])
				halt 404, "Device or service not found" if state.nil?
				
				state
			end

			get '/path*' do
				# Get the path as list of directory
				path = params['splat'][0].split('/').reject(&:empty?)

				begin
					Celluloid::Actor[:assets].get_sub_dir(path)
				rescue Assets::PathNotFoundError
					halt 404, "Path not found"
				end
			end

			get '/group*' do
				# Get the path as list of directory
				path = params['splat'][0].split('/').reject(&:empty?)

				begin
					devices = Celluloid::Actor[:assets].get_devices_by_path(path)
					result = devices.map { |device|
						states = Celluloid::Actor[:redis].get_states(device)
						# Return a hash with the device name as key and list of states as value
						{ device => states }
					}
					
					# Flatten the list of hashes into a single hash (empty hash if no result}
					result.inject(:merge) || {}
				rescue Assets::PathNotFoundError
					halt 404, "Path not found"
				end
			end

			get '/tree' do
				Celluloid::Actor[:assets].get_directory_tree
			end

			# Delete a device
			delete '/device/:device' do 
				device = params["device"]

				if Celluloid::Actor[:redis].device_exists?(device)
					Celluloid::Actor[:redis].delete_device(device)
					halt 204, "Device deleted"
				else
					halt 404, "Device not found"
				end
			end

			# Register a new device
			post '/device/:device' do 
				device = params["device"]

				if Celluloid::Actor[:redis].device_exists?(device)
					halt 200, "Device already exists"
				else
					Celluloid::Actor[:redis].add_device(device)
					halt 201, "Device added"
				end
			end

			# Save state for a device's service
			post '/state/:device/:service' do 
				validate!(%w[device service state message])

				Celluloid::Actor[:redis].set_state(params["device"], params["service"], params['state'], params['message'])
				halt 201, "State saved"
			end

			# Acknowledge an alert
			post '/state/:device/:service/acknowledge' do
				validate!(%w[device service message user])

				Celluloid::Actor[:redis].ack_state(params["device"], params["service"], params['message'], params['user'])
				halt 201, "Alert acknowledged"
			end

			# Create a new maintenance
			post '/maintenance' do
				validate!(%w[device service start end message user])
				
				begin
					starts_at = Time.parse(params['start'])
					ends_at = Time.parse(params['end'])
				rescue ArgumentError => e
					halt 400, "Wrong time format: #{e}"
				end
				
				Celluloid::Actor[:redis].set_mute(params['device'], params['service'], params['message'], params['user'], starts_at, ends_at)
				halt 201, "Maintenance saved"
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
				@server.async.shutdown
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
