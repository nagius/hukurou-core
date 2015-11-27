
require 'socket'
require 'eventmachine'
require 'pp'


class Workers
	def initialize(db, assets)
		@db = db
		@assets = assets
		@me = Socket.gethostname
		@nodes = Hash.new		# Hash of node containing list of device managed by the node
		@workers = Hash.new		# Hash of device containing list of Timer for each check
	end

	def dispatch(device)
		# TODO: optimize by keeping sorted list and length as instance variable
		nodes=@nodes.keys.sort
		nodes[device.sum % nodes.length]
	end

	def device_registered?(device)
		@nodes.values.flatten.include?(device)
	end

	def rebalance(nodes)
		# TODO: check if assets has been loaded
		$log.info "[WORKERS] Rebalance cluster with #{nodes}"

		@nodes=Hash.new
		nodes.each { |node|
			@nodes[node]=[]
		}

		d=@db.get_devices()
		d.callback { |devices|
			devices.each { |device|
				@nodes[dispatch(device)] << device
			}	
			rebalance_workers()
		}
		return d
	end

	def start_workers(device)
		$log.info "[WORKERS] Starting workers for device #{device}..."
		@workers[device]=Array.new

		@assets.get_device(device).get_services().each_pair do |service, conf|
			if conf[:remote]
				@workers[device] << EM::PeriodicTimer.new(conf[:interval]) do
					run_check(device, service, conf)
				end
			end
		end
	end

	def stop_workers(device)
		$log.info "[WORKERS] Stopping workers for device #{device}..."
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
		@nodes[@me] || []
	end

	def remove_device(device)
		target = dispatch(device)
		stop_workers(device) if target == @me
		@nodes[target].delete(device)
	end

	def add_device(device)
		target = dispatch(device)

		# Add the device to the good pool
		@nodes[target] << device

		# Start worker if target is local node
		start_workers(device) if target == @me
	end

	def rebalance_workers()
		devices_added = get_local_devices() - @workers.keys
		devices_removed = @workers.keys - get_local_devices()

		if devices_added.empty? and devices_removed.empty?
			$log.info "[WORKERS] Nothing to rebalance"
			return
		end

		# Remove old devices
		devices_removed.each { |device|
			stop_workers(device)
		}

		# Add new devices
		devices_added.each { |device|
			start_workers(device)
		}

	end
		
	def run_check(device, service, conf)
		$log.debug "[WORKERS] Checking #{service} on #{device} with #{conf}"

		# Do variable expantion
		# TODO: add hostname and IP
		# TODO: move this in Assets ?
		begin
			command = conf[:command] % conf
		rescue KeyError => e
			$log.error "[WORKERS] Cannot expand variable for #{conf[:command]}: #{e}"
			return EM::DefaultDeferrable.failed(e)
		end

		d=EM.defer_to_thread {

			output = `#{command} 2>&1`
			case $?.exitstatus
				when 0
					state = Database::State::OK
				when 1
					state = Database::State::WARN
				else
					state = Database::State::ERR
			end
			[state, output]
		}
		d.add_callback { |result|
			d1=@db.set_state(device, service, result[0], result[1])
			d1.add_errback { |e|
				$log.error "[WORKERS] #{e}"
			}
			# TODO: Do this better with chainDeferred()
		}
		d.add_errback { |e|
			message = "Failed to run #{command}: #{e}"
			d1=@db.set_state(device, service, Database::State::ERR, message)
			d1.add_errback { |e|
				$log.error "[WORKERS] #{e}"
			}
		}

		return d
	end
end

# vim: ts=4:sw=4:ai:noet
