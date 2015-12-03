
require 'celluloid/current'
require 'angelo'


# TODO: slat parameters
# TODO: params sinatra style
# TODO: raise notfound when unknown device

class Router < Angelo::Base
	content_type :json
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
		Celluloid::Actor[:assets].get_device(params["device"]).get_services()
	end

	# Get the device states
#	get '/device/:device/state' do
#		device = params["device"]
#		Celluloid::Actor[:redis].get_state(device)
#	end

	# Get check results for specific device
	get '/state/:device/:service' do 
		state = Celluloid::Actor[:redis].get_state(params["device"], params["service"])
		halt 404, "Device or service not found" if state.nil?
		
		state
	end

#	aget '/path*' do
#		# Get the path as list of directory
#		path = params['splat'][0].split('/').reject(&:empty?)
#
#		begin
#			body json @assets.get_sub_dir(path)
#		rescue PathNotFoundError
#			ahalt 404, "Path not found"
#		end
#	end
#
#	aget '/group*' do
#		# Get the path as list of directory
#		path = params['splat'][0].split('/').reject(&:empty?)
#
#		begin
#			devices=@assets.get_devices_by_path(path)
#			dl = devices.map { |device|
#				d=@db.get_state(device)
#				d.add_callback { |states|
#					# Return a hash with the device name as key and list of states as value
#					{ device => states }
#				}
#				d.add_errback { |e| ahalt 500, e.to_s }
#
#				d
#			}
#			
#			d=EM::DeferrableList.new(dl)
#			d.add_callback { |result|
#				# Reject failed results
#				result.select!{ |x| x[0] }
#
#				# Discard result status and keep the value
#				result.map!{ |x| x[1] }
#
#				# Flatten the list of hashes into a single hash (empty hash if no result}
#				hash = result.inject(:merge) || {}
#				body json hash
#			}
#			d.add_errback { |e| ahalt 500, e.to_s }
#		rescue PathNotFoundError
#			ahalt 404, "Path not found"
#		end
#	end

	get '/tree' do
		Celluloid::Actor[:assets].get_directory_tree
	end

	# Delete a device
	delete '/device/:device' do 
		device = params["device"]

		if Celluloid::Actor[:redis].device_exist?(device)
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
	post '/device/:device/:service' do 
		validate!(%w[device service state message])

		Celluloid::Actor[:redis].set_state(params["device"], params["service"], params['state'], params['message'])
		halt 201, "State saved"
	end

	# Acknowledge an alert
	post '/device/:device/:service/acknowledge' do
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
	end

	def start
		info "[API] Starting web server."
		@server = Router.run($CFG[:api][:listen], $CFG[:api][:port])
	end
end

# vim: ts=4:sw=4:ai:noet
