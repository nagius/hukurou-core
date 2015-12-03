
require 'timeout'
require 'socket'
require 'celluloid/current'

# TODO: put pool size on config
# TODO: put timeout on config

class Workers
	include Celluloid
	include Celluloid::Internals::Logger
	finalizer :shutdown

	def initialize()
		@localhost = Socket.gethostname
		@nodes = Hash.new				# Hash of node containing list of device managed by the node
		@workers = Hash.new				# Hash of device containing list of Timer for each check
		async.run
	end

	def run
		@watchdog = every($CFG[:core][:stale_freq]) { 
			async.check_stales()
		}
		@pool = Worker.pool(size: 20) 	# Pool of thread to execute checks
	end

	def shutdown()
		stop_all_workers
	end

	def dispatch(device)
		# TODO: optimize by keeping sorted list and length as instance variable
		nodes=@nodes.keys.sort
		nodes[device.sum % nodes.length]
	end

	def is_local?(device)
		dispatch(device) == @localhost
	end

	def check_stales()
		debug "[WORKERS] Checking stale states"

		states = Celluloid::Actor[:redis].get_stale_states($CFG[:core][:stale_age]) # TODO: put this on config file
		states.each { |device, service|
			if is_local?(device)
				Celluloid::Actor[:redis].set_stale_state(device, service)
			end
		}
	end

	def device_registered?(device)
		@nodes.values.flatten.include?(device)
	end

	def rebalance(nodes)
		# TODO: check if assets has been loaded
		info "[WORKERS] Rebalance cluster with #{nodes}"

		@nodes=Hash.new
		nodes.each { |node|
			@nodes[node]=[]
		}

		devices = Celluloid::Actor[:redis].get_devices()
		devices.each { |device|
			@nodes[dispatch(device)] << device
		}	
		rebalance_workers()
	end

	def start_workers(device)
		info "[WORKERS] Starting workers for device #{device}..."
		@workers[device]=Array.new

		services = Celluloid::Actor[:assets].get_device(device).get_services()
		services.each_pair do |service, conf|
			if conf[:remote]
				@workers[device] << every(conf[:interval]) do
					@pool.async.run(device, service, conf)
				end
			end
		end
	end

	def stop_workers(device)
		info "[WORKERS] Stopping workers for device #{device}..."
		# TODO: kill running checks
		@workers[device].each { |worker|
			worker.cancel()
		}
		@workers.delete(device)
	end

	def stop_all_workers()
		@workers.keys.each { |device|
			stop_workers(device)
		}
	end

	def restart_all_workers()
		@workers.keys.each { |device|
			stop_workers(device)
			start_workers(device)
		}
	end

	def get_local_devices()
		@nodes[@localhost] || []
	end

	def delete_device(device)
		target = dispatch(device)
		stop_workers(device) if target == @localhost
		@nodes[target].delete(device)
	end

	def add_device(device)
		target = dispatch(device)

		# Add the device to the good pool
		@nodes[target] << device

		# Start worker if target is local node
		start_workers(device) if target == @localhost
	end

	def rebalance_workers()
		devices_added = get_local_devices() - @workers.keys
		devices_removed = @workers.keys - get_local_devices()

		if devices_added.empty? and devices_removed.empty?
			info "[WORKERS] Nothing to rebalance"
		else
			# Remove old devices
			devices_removed.each { |device|
				stop_workers(device)
			}

			# Add new devices
			devices_added.each { |device|
				start_workers(device)
			}
		end
	end
end

class Worker
	include Celluloid
	include Celluloid::Internals::Logger
		
	def run(device, service, conf)
		debug "[WORKERS] Checking #{service} on #{device} with #{conf}"

		# Do variable expantion
		# TODO: add hostname and IP
		command = conf[:command] % conf

		output = ::IO.popen(command, :err=>[:child, :out]) do |io| 
			begin
				Timeout.timeout(2) { io.read }
			rescue Timeout::Error
				Process.kill 9, io.pid
				raise
			end
		end

		case $?.exitstatus
			when 0
				state = Database::State::OK
			when 1
				state = Database::State::WARN
			else
				state = Database::State::ERR
		end

		Celluloid::Actor[:redis].set_state(device, service, state, output)
	rescue StandardError => e
		# Select the good error message
		message = case e
			when KeyError
				"Cannot expand variable for #{conf[:command]}: #{e}"
			when Timeout::Error
				"Timeout running #{command}"
			else
				"Failed to run #{command}: #{e}"
		end

		warn "[WORKERS] #{message}"
		Celluloid::Actor[:redis].set_state(device, service, Database::State::ERR, message)
	end

end

# vim: ts=4:sw=4:ai:noet
