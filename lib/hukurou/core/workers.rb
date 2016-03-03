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

require 'timeout'
require 'socket'

module Hukurou
	module Core
		class Workers
			include Celluloid
			include Celluloid::Internals::Logger
			finalizer :shutdown

			def initialize()
				@localhost = Socket.gethostname
				@nodes = Hash.new				# Hash of node containing list of device managed by the node
				@workers = Hash.new				# Hash of device containing list of Timer for each check
				async.setup
			end

			# Second-step initialize Celluloid actor
			def setup
				@watchdog = every(60) { 
					# Check for stale states every minutes
					async.check_stales()
				}
				@pool = Worker.pool(size: Config[:core][:pool_size])	# Pool of thread to execute checks
			end

			def shutdown()
				@watchdog.cancel unless @watchdog.nil?
				stop_all_workers
			rescue StandardError => e
				debug "[WORKERS] Finalizer crashed: #{e}"
			end

			# Return the node managing this device
			#
			# @param device [String] Device name
			# @return [String] Node name
			def dispatch(device)
				# TODO: optimize by keeping sorted list and length as instance variable
				nodes=@nodes.keys.sort
				nodes[device.sum % nodes.length]
			end

			# Tell if the device is managed by the local node
			#
			# @param [String] Device name
			# @return [Boolean]
			def is_local?(device)
				dispatch(device) == @localhost
			end

			# Check if some service are stale and update database
			def check_stales()
				debug "[WORKERS] Checking stale states"

				states = Celluloid::Actor[:redis].get_stale_services(Config[:services][:max_age])
				states.each { |device, service|
					if is_local?(device)
						Celluloid::Actor[:redis].set_stale_state(device, service)
					end
				}
			end

			# Tell if a device is managed by any node
			#
			# @param [String] Device name
			# @return [Boolean]
			def device_registered?(device)
				@nodes.values.flatten.include?(device)
			end

			# Redefine which node is in charge of which device
			# Used to rebalance the cluster when a node is leaving or joining
			#
			# @param nodes [Array<String>] List of nodes
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

			# Start periodic checks for all services of this device
			#
			# @param device [String] Device name
			def start_workers(device)
				info "[WORKERS] Starting workers for device #{device}..."
				@workers[device]=Array.new

				services = Celluloid::Actor[:assets].get_services(device)
				services.each_pair do |service, conf|
					if conf[:remote]
						@workers[device] << every(conf[:interval]) do
							@pool.async.run(device, service, conf)
						end
					end
				end
			rescue Assets::SubstitutionError => e
				error "[WORKERS] Failed to start workers: #{e}"
			end

			# Suspend periodic checks for all services of this device
			#
			# @param device [String] Device name
			def stop_workers(device)
				if @workers.include?(device)
					info "[WORKERS] Stopping workers for device #{device}..."
				
					@workers[device].each { |worker|
						worker.cancel()
					}
					@workers.delete(device)
				end
			end

			# Suspend all periodic checks managed by the local node
			def stop_all_workers()
				@workers.keys.each { |device|
					stop_workers(device)
				}
			end

			# Restart all periodic checks managed by the local node
			# Used after a change in services's definitions
			def restart_all_workers()
				@workers.keys.each { |device|
					stop_workers(device)
					start_workers(device)
				}
			end

			# Return the list of devices managed by the local node
			#
			# @return [Array<Strinq>] List of devices
			def get_local_devices()
				@nodes[@localhost] || []
			end

			# Remove a device from the managed list and stop associated workers
			#
			# @param [String] Device name
			def delete_device(device)
				target = dispatch(device)
				stop_workers(device) if target == @localhost
				@nodes[target].delete(device)
			end

			# Add a device to the managed list and start associated workers
			#
			# @param [String] Device name
			def add_device(device)
				target = dispatch(device)

				# Add the device to the good pool
				@nodes[target] << device

				# Start worker if target is local node
				start_workers(device) if target == @localhost
			end

			# Stop workers of removed devices and start workers of added devices
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
				
			# Execute a check command and save the result in DB
			#
			# @param device [String] Device ame
			# @param service [String] Service name
			# @param conf [Hash] Configuration of the service's check
			def run(device, service, conf)
				debug "[WORKERS] Checking #{service} on #{device} with #{conf}"

				begin
					output = ::IO.popen(conf[:command], :err=>[:child, :out]) do |io| 
						begin
							Timeout.timeout(Config[:services][:timeout]) { io.read }
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
						when 3
							state = Database::State::STALE
						else
							state = Database::State::CRIT
					end

					if Thread.main[:shutdown]
						warn "[WORKERS] Shutdown in progress, #{device}:#{service} update cancelled."
					elsif not Celluloid::Actor[:workers].device_registered?(device)
						warn "[WORKERS] Device #{device} not registered, #{service} update cancelled."
					else
						Celluloid::Actor[:redis].set_state(device, service, state, output)
					end
				rescue StandardError => e
					# Select the good error message
					message = case e
						when Timeout::Error
							"Timeout running #{conf[:command]}"
						else
							"Failed to run #{conf[:command]}: #{e}"
					end

					warn "[WORKERS] #{message}"
					Celluloid::Actor[:redis].set_state(device, service, Database::State::CRIT, message)
				end
			rescue DeadActorError
				if not Thread.main[:shutdown]
					warn "[WORKERS] Redis actor is dead."
				end
			end
		end
	end
end

# vim: ts=4:sw=4:ai:noet
