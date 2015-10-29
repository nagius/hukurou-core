require 'async-rack'
require 'sinatra/base'
require 'sinatra/json'
require 'sinatra/async'
require 'eventmachine'

require 'pp'

# BUGFIX: 404 request with async-rack fails with an uncaught exception
# BUGFIX: Catching exception for logging doesn't work
# BUGFIX: Sinatra crashes on a request folowing a 404

# Monkey patching Rack::CommonLogger to change log format
# Taken from lib/rack/commonlogger.rb - v1.5.2
module Rack
  class CommonLogger
  	FORMAT = %{[%s] INFO [RACK] %s %s "%s %s%s %s" %d %s %0.4f\n}

    def log(env, status, header, began_at)
      now = Time.now
      length = extract_content_length(header)

      logger = @logger || env['rack.errors']
      logger.write FORMAT % [
        now.strftime("%Y-%m-%d %H:%M:%S %z"),
        env['HTTP_X_FORWARDED_FOR'] || env["REMOTE_ADDR"] || "-",
        env['HTTP_X_REMOTE_USER'] || env["REMOTE_USER"] || "-",
        env["REQUEST_METHOD"],
        env["PATH_INFO"],
        env["QUERY_STRING"].empty? ? "" : "?"+env["QUERY_STRING"],
        env["HTTP_VERSION"],
        status.to_s[0..3],
        length,
        now - began_at ]
    end
  end
end


class Api < Sinatra::Base
	register Sinatra::Async
	# BUG: Namespace plugin doesn't work with async
	
	def initialize(db, assets, workers, network)
		super()
		@db = db
		@assets = assets
		@workers = workers
		@network = network
		$log.info "[RACK] Starting Web API..."
	end

    # Framework configuration
    configure do
		set :show_exception, false
        enable :logging
		disable :traps
		set :threaded, false
    end

	# BUG: This function is not always executed when it should be
	def handle_exception!(e)
		case e
			when Sinatra::NotFound
				$log.warn "[RACK] Not Found: #{request.env['REQUEST_METHOD']} #{request.env['PATH_INFO']}"
				ahalt 404, "Not found"
			else
				$log.error "[RACK] Exception catched #{e}"
				e.backtrace.each { |trace|
					$log.error "[RACK] \t #{trace}"
				}
		end
	end

	# Get checks definition for the device
	aget '/device/:device/config' do |device|
		body json @assets.get_device(device).get_services()
	end

	# Get the device states
	aget '/device/:device/state' do |device|
		@db.get_state(device).callback { |result|
			body json result
		}
	end

	# Get check results for specific device, with history
	aget '/state/:device/:service' do |device, service|
		@db.get_service(device, service).callback { |result|
			body json result
		}
	end

	aget '/path*' do
		# Get the path as list of directory
		path = params['splat'][0].split('/').reject(&:empty?)

		begin
			body json @assets.get_sub_dir(path)
		rescue PathNotFoundError
			ahalt 404, "Path not found"
		end
	end

	aget '/group*' do
		# Get the path as list of directory
		path = params['splat'][0].split('/').reject(&:empty?)

		begin
			devices=@assets.get_devices_by_path(path)
			dl = devices.map { |device|
				d=@db.get_state(device)
				d.add_callback { |states|
					# Return a hash with the device name as key and list of states as value
					{ device => states }
				}
				d.add_errback { |e| ahalt 500, e.to_s }

				d
			}
			
			d=EM::DeferrableList.new(dl)
			d.add_callback { |result|
				# Flatten the list of hashes into a single hash (empty hash if no result}
				hash = result.inject(:merge) || {}
				body json hash
			}
			d.add_errback { |e| ahalt 500, e.to_s }
		rescue PathNotFoundError
			ahalt 404, "Path not found"
		end
	end

	aget '/tree' do
		body json @assets.get_directory_tree
	end

	# List devices in this DC
	aget '/devices' do 
		@db.get_devices().callback { |result|
			body json result
		}
	end	

	# Delete a device
	adelete '/device/:device' do |device|
		if @workers.device_registered?(device)
			@network.device_deleted(device)
			ahalt 204, "Device deleted"
		else
			ahalt 404, "Device not found"
		end
	end

	# Register a new device
	apost '/device/:device' do |device|
		@network.device_added(device)
		ahalt 201, "Device added"
	end

	# Save state for a device's service
	apost '/device/:device/:service' do |device, service|
		%w[state message].each do |param|
			halt 400, "Parameter '#{param}' missing." unless params.has_key? param
		end

		d=@db.save_state(device, service, params['state'], params['message'])
		d.callback { |is_new| 
			@network.device_added(device) if is_new
			ahalt 201, "State saved"
		}
		d.errback { |e| ahalt 500, e.to_s }
	end

	# Acknowledge an alert
	apost '/device/:device/:service/acknowledge' do |device, service|
		# TODO: factorize params check
		%w[message user].each do |param|
			halt 400, "Parameter '#{param}' missing." unless params.has_key? param
		end

		d=@db.ack_state(device, service, params['message'], params['user'])
		d.callback { ahalt 201, "Alert acknowledged" }
		d.errback { |e| ahalt 500, e.to_s }
	end

	# Create a new maintenance
	apost '/maintenance' do
		%w[device service start end message user].each do |param|
			halt 400, "Parameter '#{param}' missing." unless params.has_key? param
		end
		
		d=@db.add_maintenance(params['device'], params['service'], params['start'], params['end'], params['message'], params['user'])
		d.callback { ahalt 201, "Maintenance saved" }
		d.errback { |e| ahalt 500, e.to_s }
	end

end

# vim: ts=4:sw=4:ai:noet
