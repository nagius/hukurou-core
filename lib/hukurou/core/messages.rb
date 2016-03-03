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

require 'socket'
require 'json'

module Hukurou
	module Core
		module Message
			class AbstractMessage
				attr_reader :src

				# Create a new message
				#
				# @param msg [Hash] Message content
				def initialize(msg=nil)
					if msg.nil?
						@src=Socket.gethostname
					else
						['src', 'data'].each do |k|
							raise KeyError, "Key #{k} is missing" unless msg.has_key? k
						end

						@src=msg['src']
						@data=msg['data']
					end
				end

				# Get the type of a message
				#
				# @return [String] Type name
				def type()
					TYPE.each_pair do |k,v|
						if self.instance_of?(v)
							return k
						end
					end
					raise ParseError, "Unknown type #{self.class}"
				end

				# Convert the message data in JSON
				#
				# @return [String] JSON document
				def serialize()
					{:type => type(), :src => @src, :data => @data}.to_json
				end

			end

			class JoinRequest < AbstractMessage
				def initialize(msg=nil)
					super
					@data=Config[:secret] if msg.nil?
				end

				# Tell if the token in the message is valid
				#
				# @return [Boolean]
				def token_ok?
					@data==Config[:secret]
				end
			end

			class Denied < AbstractMessage
			end

			class Granted < AbstractMessage
				# Return the list of cluster nodes actually running
				#
				# @return [Array<String>]
				def members
					@data
				end

				# Set the list of cluster nodes
				#
				# @param members [Array<String>] List of node name
				def set_members(members)
					@data=members
					return self
				end	
			end

			class Join < AbstractMessage
			end

			class Leave < AbstractMessage
			end

			class Heartbeat < AbstractMessage
			end

			class Eject < AbstractMessage
				def host
					@data
				end

				def set_host(host)
					@data=host
					return self
				end	
			end

			# Map each type of message
			TYPE = {
				'join' 		=> Join,
				'leave' 	=> Leave,
				'hb' 		=> Heartbeat,
				'eject' 	=> Eject,
				'ask' 		=> JoinRequest,
				'denied' 	=> Denied,
				'grant' 	=> Granted,
			}

			# Parse UDP data and return the corresponding Message subclass
			#
			# @param raw [String] JSON data
			# @param ip [String] Source IP
			# @return [AbstractMessage]
			def Message.get(raw, ip)
				begin
					data=JSON.parse(raw)

					return TYPE[data['type']].new(data)
				rescue NoMethodError, KeyError, JSON::ParserError
					raise ParseError, "Corrupted message received from #{ip}" 
				end
			end

		end
	end
end

class Hukurou::Core::Message::ParseError < StandardError
end

# vim: ts=4:sw=4:ai:noet
