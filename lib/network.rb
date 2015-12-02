#!/usr/bin/env ruby


require 'socket'
require 'celluloid/current'
require 'celluloid/io'
require_relative 'messages'


module Celluloid
	module IO
		class UDPSocket
			# Forward setsockopt to allow broadcast packet
			def_delegators :@socket, :setsockopt
		end
	end
end


# TODO: set IP TOS field to Minimize-Delay
# TODO: rename intercom ? NetworkCluster ?
class Network
	include Celluloid::IO
	include Celluloid::Internals::Logger
	finalizer :shutdown
	
	def initialize
		@hb = Message::Heartbeat.new	# Generate the heartbeat message only once
		@me = Socket.gethostname		# My name
		@status={}						# List of remote nodes with timestamps

		@socket = Celluloid::IO::UDPSocket.new
		@socket.bind("0.0.0.0", 6666)
		@socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)

		async.listen
		async.join_cluster
	end

	def shutdown
		leave_cluster
	end

	def listen()
		while @socket
			data, (_, port, _, ip) = @socket.recvfrom(1400) # TODO: check if good number
			debug "[NET] Msg received form #{ip}:#{port} - #{data}"
			async.process_data(data, ip, port)
		end
	rescue EOFError => e
		error "[NET] Socket error: #{e}"
	end

	def process_data(data, ip, port)
		# Parse received message
		begin
			msg=Message::get(data, ip)

			# Discard own messages
			return if msg.src == @me

			# Dispatch message
			case msg
				when Message::Heartbeat
					if @status.keys.include? msg.src
						@status[msg.src]=Time.now
					else
						warn "[NET] Discarding heartbeat from non registered node #{msg.src}"
					end
				when Message::JoinRequest
					if msg.token_ok?
						reply(Message::Granted.new.set_members(get_nodes()), ip, port)
					else
						warn "[NET] Bad token form #{msg.src}. Refusing this node."
						reply(Message::Denied.new, ip, port)
					end
				when Message::Granted
					@members[msg.src]=msg.members
				when Message::Denied
					@denied=true
				when Message::Join
					info "[NET] New node in cluster: #{msg.src}"
					@status[msg.src]=Time.now
					notify_node_change()
				when Message::Leave
					info "[NET] Node leaving cluster: #{msg.src}"
					remove_node(msg.src)
				when Message::Eject
					if msg.host == @me
						warn "[NET] I've been kicked out by #{msg.src}. Shutting down."
						Celluloid.shutdown
					else
						info "[NET] Node #{msg.host} rejected by #{msg.src}. Removing from cluster."
						remove_node(msg.host)
					end
				when Message::DeviceAdded
					info "[NET] Device added: #{msg.device}"
					notify_device_change(msg.device, :add)
				when Message::DeviceDeleted
					info "[NET] Device deleted: #{msg.device}"
					notify_device_change(msg.device, :delete)
				else
					info "[NET] Unknown message type #{msg.class} from #{ip}"
			end
		rescue Message::ParseError => e
			error "[NET] #{e}"
		end
	end

	def start_heartbeat()
		@timer_hb=every(1) {
			broadcast(@hb)
		}
	end

	def stop_heartbeat()
		@timer_hb.cancel unless @timer_hb.nil?
	end

	def start_watchdog()
		@timer_wd=every(2) {
			@status.each_pair { |node, ts|
				if Time.now - ts > 10
					warn "[NET] Failure detected for node #{node}. Removing from cluster."
					broadcast(Message::Eject.new.set_host(node))
					async.remove_node(node)
				end
			}	
		}
	end

	def stop_watchdog()
		@timer_wd.cancel unless @timer_wd.nil?
	end

	def join_cluster()
		@members=Hash.new
		@denied=false

		broadcast(Message::JoinRequest.new)

		# Wait response from others members
		sleep 2  # This is non blocking for the current thread

		# TODO verify coherence
		if @denied
			info "[NET] Cluster join refused: Access denied"
			Celluloid.shutdown
		else
			broadcast(Message::Join.new)

			# Initialize status for watchdog
			@members.keys.each { |node|
				@status[node]=Time.now
			}

			start_heartbeat()
			start_watchdog()
			notify_node_change()

			# Return the list of cluster's member (excluding local node)
			@members.keys
			info "[NET] Cluster joined with members: #{@members}"

			Celluloid::Actor[:api].async.start
		end
	end

	def leave_cluster()
		info "[NET] Leaving cluster."
		stop_watchdog()
		stop_heartbeat()
		broadcast(Message::Leave.new)
	end

	def get_nodes()
		@status.keys + [@me]
	end

	# TODO: move this to pub/sub in Redis
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
			@socket.send(msg.serialize(), 0, '<broadcast>', 6666)
		end

		def reply(msg, host, port)
			@socket.send(msg.serialize(), 0, host, port)
		end

		def remove_node(node)
			@status.delete(node)
			notify_node_change()
		end

		def notify_node_change()
			Celluloid::Actor[:workers].rebalance(get_nodes())
		end

		def notify_device_change(device, action)
			puts "device change"
		end

end

# vim: ts=4:sw=4:ai:noet
