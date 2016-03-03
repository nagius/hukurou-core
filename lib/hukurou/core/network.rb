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

# TODO: set IP TOS field to Minimize-Delay

require 'socket'

module Hukurou
	module Core
		class Network
			include Celluloid::IO
			include Celluloid::Internals::Logger
			finalizer :shutdown
			
			def initialize
				@hb = Message::Heartbeat.new	# Generate the heartbeat message only once
				@localhost = Socket.gethostname		# My name
				@status={}						# List of remote nodes with timestamps

				@socket = Celluloid::IO::UDPSocket.new
				@socket.bind(Config[:core][:listen], Config[:core][:port])
				@socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)

				async.listen
				async.join_cluster
			end

			def shutdown
				leave_cluster
			rescue StandardError => e
				debug "[NET] Finalizer crashed: #{e}"
			end

			# Start listening to the socket
			def listen()
				while @socket
					data, (_, port, _, ip) = @socket.recvfrom(1400) # TODO: check if good number
					debug "[NET] Msg received form #{ip}:#{port} - #{data}"
					async.process_data(data, ip, port)
				end
			rescue EOFError => e
				error "[NET] Socket error: #{e}"
			end

			# Handle an incomming message
			#
			# @param data [String] Raw data
			# @param ip [String] Source IP
			# @param port [String] Source port
			def process_data(data, ip, port)
				# Parse received message
				begin
					msg=Message::get(data, ip)

					# Discard own messages
					return if msg.src == @localhost

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
							if msg.host == @localhost
								warn "[NET] I've been kicked out by #{msg.src}. Shutting down."
								Celluloid.shutdown
							else
								info "[NET] Node #{msg.host} rejected by #{msg.src}. Removing from cluster."
								remove_node(msg.host)
							end
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

			# Send a request to join the cluster and start everything if accepted
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
					info "[NET] Cluster joined with members: #{@members.keys}"

					# Start API web server
					Celluloid::Actor[:api].async.start

					# (re)start others component
					notify_node_change()
				end
			end

			def leave_cluster()
				info "[NET] Leaving cluster."
				stop_watchdog()
				stop_heartbeat()
				broadcast(Message::Leave.new)
			end

			# Return the list of nodes in the cluster
			#
			# @return [Array<String>]
			def get_nodes()
				@status.keys + [@localhost]
			end

			private

				# Broadcast a message to others node
				#
				# @param msg [AbstractMessage]
				def broadcast(msg)
					@socket.send(msg.serialize(), 0, '<broadcast>', Config[:core][:port])
				end

				# Reply to a previously received message
				#
				# @param msg [AbstractMessage] Message to send
				# @param host [String] Destination hostname or IP
				# @param port [String] Destination port
				def reply(msg, host, port)
					@socket.send(msg.serialize(), 0, host, port)
				end

				# Remove a node from the cluster
				#
				# @param node [String] Node name
				def remove_node(node)
					@status.delete(node)
					notify_node_change()
				end

				def notify_node_change()
					Celluloid::Actor[:workers].rebalance(get_nodes())
				end

		end
	end
end

# vim: ts=4:sw=4:ai:noet
