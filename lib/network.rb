#!/usr/bin/env ruby


require 'eventmachine'
require 'socket'
require_relative 'messages'


# TODO: set IP TOS field to Minimize-Delay
class NetworkHandler < EM::Connection
	def initialize
		super
		
		# Auto-detect IP of interface
		@iface = Socket.getifaddrs.detect{ |iface| iface.name == $CFG[:core][:iface] and iface.addr.ipv4? }
	
		raise "Couldn't find interface: #{$CFG[:core][:iface]}" if @iface.nil?

		@hb = Message::Heartbeat.new	# Generate the heartbeat message only once
		@me = Socket.gethostname		# My name
		@status={}						# List of remote nodes with timestamps
		@node_callbacks=[]  			# List of callback to fire when a cluster change occurs (node added or removed)
		@device_callbacks=[]  			# List of callback to fire when a device is added or removed
	end

	def self.get_instance()
		# FIXME: debug this to change to @iface.addr.ip_address
		EM::open_datagram_socket("0.0.0.0", $CFG[:core][:port], NetworkHandler)
	end

	# Register callback
	def on_node_change(&block)
		@node_callbacks << block
	end

	def on_device_change(&block)
		@device_callbacks << block
	end

	def receive_data(data)
		# Get remote infos
		port, ip = Socket.unpack_sockaddr_in(get_peername())
		
		# Discard own messages
		return if ip == @iface.addr.ip_address

		$log.debug "[NET] Msg received form #{ip}:#{port} - #{data}"

		# Parse received message
		begin
			msg=Message::get(data, ip)

			# Dispatch message
			case msg
				when Message::Heartbeat
					if @status.keys.include? msg.src
						@status[msg.src]=Time.now
					else
						$log.warn "[NET] Discarding heartbeat from non registered node #{msg.src}"
					end
				when Message::JoinRequest
					if msg.token_ok?
						reply(Message::Granted.new.set_members(get_nodes()))
					else
						$log.warn "[NET] Bad token form #{msg.src}. Refusing this node."
						reply(Message::Denied.new)
					end
				when Message::Granted
					@members[msg.src]=msg.members
				when Message::Denied
					@denied=true
				when Message::Join
					$log.info "[NET] New node in cluster: #{msg.src}"
					@status[msg.src]=Time.now
					notify_node_change()
				when Message::Leave
					$log.info "[NET] Node leaving cluster: #{msg.src}"
					remove_node(msg.src)
				when Message::Eject
					if msg.host == @me
						$log.warn "[NET] I've been kicked out by #{msg.src}. Shutting down."
						EM.stop
					else
						$log.info "[NET] Node #{msg.host} rejected by #{msg.src}. Removing from cluster."
						remove_node(msg.host)
					end
				when Message::DeviceAdded
					$log.info "[NET] Device added: #{msg.device}"
					notify_device_change(msg.device, :add)
				when Message::DeviceDeleted
					$log.info "[NET] Device deleted: #{msg.device}"
					notify_device_change(msg.device, :delete)
				else
					$log.info "[NET] Unknown message type #{msg.class} from #{ip}"
			end
		rescue Message::ParseError => e
			$log.error "[NET] #{e}"
		end
	end

	def start_heartbeat()
		@timer_hb=EM::PeriodicTimer.new(1) do
			broadcast(@hb)
		end
	end

	def stop_heartbeat()
		if not @timer_hb.nil?
			@timer_hb.cancel
		end
	end

	def start_watchdog()
		@timer_wd=EM::PeriodicTimer.new(2) do
			@status.each_pair { |node, ts|
				if Time.now - ts > 10
					$log.warn "[NET] Failure detected for node #{node}. Removing from cluster."
					broadcast(Message::Eject.new.set_host(node))
					EM.next_tick { remove_node(node) }
				end
			}	
		end
	end

	def stop_watchdog()
		if not @timer_wd.nil?
			@timer_wd.cancel
		end
	end

	def join_cluster()
		@members=Hash.new
		@denied=false

		broadcast(Message::JoinRequest.new)
		# TODO: add a retry process

		d=EM::DefaultDeferrable.new

		# Check response from others members
		EM.add_timer(2) {
			# TODO verify coherence
			if @denied
				d.fail("Access denied")
			else
				broadcast(Message::Join.new)

				# Initialize status for watchdog
				@members.keys.each { |node|
					@status[node]=Time.now
				}

				start_heartbeat()
				start_watchdog()
				notify_node_change()
				d.succeed(@members.keys)
			end
		}

		return d
	end

	def leave_cluster()
		stop_watchdog()
		stop_heartbeat()
		broadcast(Message::Leave.new)
	end

	def get_nodes()
		@status.keys + [@me]
	end

	def device_added(device)
		broadcast(Message::DeviceAdded.new.set_device(device))
		notify_device_change(device, :add)		# Also locally notify because our own message are discarded
	end

	def device_deleted(device)
		broadcast(Message::DeviceDeleted.new.set_device(device))
		notify_device_change(device, :delete)	# Also locally notify because our own message are discarded
	end

	private

		def broadcast(msg)
			# TODO assert msg is Message
			send_datagram(msg.serialize(), @iface.broadaddr.ip_address, $CFG[:core][:port])
		end

		def reply(msg)
			send_data(msg.serialize())
		end

		def remove_node(node)
			@status.delete(node)
			notify_node_change()
		end

		def notify_node_change()
			EM.next_tick {
				@node_callbacks.each { |c| c.call(get_nodes()) }
			}
		end

		def notify_device_change(device, action)
			EM.next_tick {
				@device_callbacks.each { |c| c.call(device, action) }
			}
		end

end

# vim: ts=4:sw=4:ai:noet
