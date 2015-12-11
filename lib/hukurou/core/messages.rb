
require 'socket'
require 'json'

module Hukurou
	module Core
		module Message
			class AbstractMessage
				attr_reader :src

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

				def type()
					TYPE.each_pair do |k,v|
						if self.instance_of?(v)
							return k
						end
					end
					raise ParseError, "Unknown type #{self.class}"
				end

				def serialize()
					{:type => type(), :src => @src, :data => @data}.to_json
				end

			end

			class JoinRequest < AbstractMessage
				def initialize(msg=nil)
					super
					@data=$CFG[:shared_secret] if msg.nil?
				end

				def token_ok?
					@data==$CFG[:shared_secret]
				end
			end

			class Denied < AbstractMessage
			end

			class Granted < AbstractMessage
				def members
					@data
				end

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
			def Message.get(raw, ip)
				begin
					data=JSON.parse(raw)

					return TYPE[data['type']].new(data)
				rescue NoMethodError, KeyError, JSON::ParserError
					raise ParseError, "Corrupted message received from #{ip}" 
				end
			end

			class ParseError < StandardError
			end
		end
	end
end
# vim: ts=4:sw=4:ai:noet
