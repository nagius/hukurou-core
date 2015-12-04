# TODO: document datamodel
# TODO: YARD documentation

# TODO: add history on pub/sub change state ?

require 'celluloid/current'
require 'celluloid/io'
require "celluloid/redis"
require "json"

class Database
	include Celluloid::IO
	include Celluloid::Internals::Logger
	finalizer :shutdown

	class State
		OK = "OK"
		ERR = "ERROR"
		WARN = "WARN"
		STALE = "STALE"
	end

	def initialize()
		async.run
	end

	def run()
		# Force celluloid driver for Redis
		config = $CFG[:database].merge(:driver => "celluloid")

		# Open two redis connection, one for data, one for events
		@redis = ::Redis.new(config)
		@pubsub = ::Redis.new(config)

		# Check mimium version (needed for *scan features)
		if @redis.info["redis_version"] < "2.8.0"
			error "Redis version must be >= 2.8.0"
			Celluloid.shutdown
		end

		@pubsub.subscribe(:events) { |on|
			on.message { |channel, message|
				async.handle_event(message)
			}
		}
	rescue ::Redis::CannotConnectError => e
		error "Cannot connect to Redis: #{e}"
		Celluloid.shutdown
	end

	def shutdown()
		@pubsub.unsubscribe(:events)
		#@pubsub.quit  # This crash with a <NoMethodError: undefined method `disconnect'> Bug ?
		@redis.quit
	end

	def set_state(device, service, state, message)
		# NOTE: service can be a symbol

        debug "[REDIS] Saving state #{[device, service, state, message]}"

		now = Time.now.to_i

		# Data for state:<device>:<service>
		key_state = "state:#{device}:#{service}"
		data = {
			:state => state,
			:message => message,
			:last_seen => now,
			:starts_at => now,
			:event => false
		}

		if not @redis.sismember("devices", device)
			# New device
			@redis.mapped_hmset(key_state, data)
			add_device(device)
			# TODO: add history
		else
			if @redis.hget(key_state, :state) == state
				# Same state
				@redis.hmset(key_state, :message, message, :last_seen, now)
			else
				# State change
				@redis.mapped_hmset(key_state, data)

				# Cancel acknowledge
				cancel_ack(key_state)

				state_changed(key_state)
				# TODO: add history
			end
		end
			
		@redis.zadd("last_seens", now, "#{device}:#{service}")
	rescue IOError => e
		warn "IOError with redis, reconnecting: #{e}"
		@redis.client.reconnect
		retry
	end

	def set_stale_state(device, service)
		key_state = "state:#{device}:#{service}"

		if @redis.hget(key_state, :state) != State::STALE
			info "[REDIS] Detected stale state: #{device} #{service}"
			@redis.hmset(key_state, :state, State::STALE, :starts_at, Time.now.to_i)
			cancel_ack(key_state)
			state_changed(key_state)
		end
	end

	def get_stale_states(age)
		@redis.zrangebyscore("last_seens", 0, (Time.now.to_i - age)).map { |key|
			key.split(":")
		}
	end

	def get_state(device, service)
		key_state = "state:#{device}:#{service}"

		if @redis.exists(key_state)
			state = @redis.mapped_hmget(key_state, :state, :message, :last_seen, :starts_at, :ack_id, :mute_id)

			# Convert timestame to Time
			state[:last_seen] = Time.at(state[:last_seen].to_i)
			state[:starts_at] = Time.at(state[:starts_at].to_i)

			# Add ack infos
			if not state[:ack_id].nil?
				state[:ack] = @redis.mapped_hmget("ack:#{state[:ack_id]}", :message, :user, :created_at)
				state[:ack][:created_at] = Time.at(state[:ack][:created_at].to_i)
			end

			# Add mute infos
			if not state[:mute_id].nil?
				state[:mute] = get_mute(state[:mute_id])
			end

			state
		else
			nil
		end
	end

	def get_all_states()
		@redis.scan_each(:match => "state:*").map { |key|
			device, service = key.split(":")[1,2]
			{ :device => device, :service => service }
		}
	end

	def get_states(device)
		@redis.scan_each(:match => "state:#{device}:*").map { |key|
			service = key.split(":")[2]
			{ service => get_state(device, service) }.symbolize_keys
		}.inject(:merge)
	end

	def get_devices()
		@redis.smembers("devices")
	end

	def device_exists?(device)
		@redis.sismember("devices", device)
	end

	def add_device(device)
		if not Celluloid::Actor[:workers].device_registered?(device)
			info "[REDIS] New device: #{device}"
			@redis.sadd("devices", device)
			@redis.publish(:events, {:event => "device_added", :device => device}.to_json)
		end
	end

	def delete_device(device)
		info "[REDIS] Delete device: #{device}"

		@redis.srem("devices", device)

		# WARNING: *scan do not work inside a pipeline or a multi
		@redis.scan_each(:match => "state:#{device}:*") { |key_state|
			delete_state_by_key(key_state)
		}

		@redis.zscan_each("last_seens", :match => "#{device}:*") { |key|
			@redis.zrem("last_seens", key[0])
		}

		@redis.publish(:events, {:event => "device_deleted", :device => device}.to_json)
	end

	def delete_state(device, service)
		info "[REDIS] Delete state: #{device}:#{service}"
		delete_state_by_key("state:#{device}:#{service}")
	end

	def ack_state(device, service, message, user)
		key_state = "state:#{device}:#{service}"

		if not @redis.hexists(key_state, :ack_id) # Do nothing if already acked
			info "[REDIS] Acknowledge state: #{device}:#{service}"
			id = @redis.incr("next_ack_id")

			ack = {
				:id => id,
				:message => message,
				:user => user,
				:state => key_state,
				:created_at => Time.now.to_i
			}

			@redis.mapped_hmset("ack:#{id}", ack)
			@redis.hset(key_state, :ack_id, id)

			id	# Return the id of the created ack record
		else
			nil	# Return nil if nothing done
		end
	end

	def set_mute(devices, services, message, user, starts_at, ends_at)
		# TODO assets: starts_at and ends_at must be Time object
		# TODO devices and services must be Array

		info "[REDIS] Added mute: #{devices}:#{services} by #{user} from #{starts_at} to #{ends_at}"
		# TODO: store exact list or wildcard ??

		id = @redis.incr("next_mute_id")
		mute = {
			:id => id,
			:devices => devices.to_json,
			:services => services.to_json,
			:message => message,
			:user => user,
			:starts_at => starts_at.to_i,
			:ends_at => ends_at.to_i
		}

		@redis.mapped_hmset("mute:#{id}:obj", mute)

		# Mute all existing specified states
		devices.each { |device|
			services.each { |service|
				key_state = "state:#{device}:#{service}"
				if @redis.exists(key_state)
					already_muted = @redis.hexists(key_state, :mute_id)

					@redis.sadd("mute:#{id}:states", key_state)
					@redis.hset(key_state, :mute_id, id)

					# Only trigger state changed if it wasn't already muted
					state_changed(key_state) unless already_muted
					# TODO: add history
				end
			}
		}
		
		# Return the Id of created mute record
		id
	end

	def get_mutes()
		mutes = []
		@redis.scan_each(:match => "mute:*:obj") { |key|
			mutes << get_mute(key)
		}

		mutes
	end

	def get_mute(key)
		# Convert to key if Id given
		key = "mute:#{key}:obj" unless key.to_s.include? ":"

		if @redis.exists(key)
			mute = @redis.mapped_hmget(key, :id, :devices, :services, :message, :user, :starts_at, :ends_at)

			# Parse JSON sub-elements
			mute[:devices] = JSON.parse(mute[:devices])
			mute[:services] = JSON.parse(mute[:services])

			# Convert timestame to Time
			mute[:starts_at] = Time.at(mute[:starts_at].to_i)
			mute[:ends_at] = Time.at(mute[:ends_at].to_i)

			mute
		else
			nil
		end
	end

	def delete_mute(id)
		info "[REDIS] Mute ##{id} deleted"

		# Get impacted states by this mute
		muted_states = @redis.smembers("mute:#{id}:states").to_a

		# Delete mute objects
		@redis.del("mute:#{id}:states")
		@redis.del("mute:#{id}:obj")

		# Get list of all states concerned by another mute
		# If multiple mute for one state, just keep one (not sorted)
		all_muted_states = {} 
		@redis.scan_each(:match => "mute:*:states") { |key|
			id = key.split(":")[1]
			@redis.smembers(key).each { |key_state| 
				all_muted_states[key_state] = id
			}
		}

		# Chech if impacted states are also concerned by another mute
		muted_states.each { |key_state|
			if all_muted_states[key_state].nil?
				# No others mute, unmute this state
				@redis.hdel(key_state, :mute_id)
				state_changed(key_state)
			else
				# Update mute reference to the previous one
				@redis.hset(key_state, :mute_id, all_muted_states[key_state])
			end
		}
	end

	private

		def state_changed(key_state)
			info "[REDIS] State change for #{key_state}"

			(_, device, service) = key_state.split(':')
			@redis.publish(:events, {:event => "state_change", :device => device, :service => service }.to_json)
		end

		def cancel_ack(key_state)
			ack_id = @redis.hget(key_state, :ack_id)
			if not ack_id.nil?
				info "[REDIS] Acknowledge ##{ack_id} cancelled for #{key_state}"
				@redis.hdel(key_state, :ack_id)	
				@redis.del("ack:#{ack_id}")
			end
		end

		def delete_state_by_key(key_state)
			# Delete acknowledge
			ack_id = @redis.hget(key_state, :ack_id)
			@redis.del("ack:#{ack_id}") unless ack_id.nil?

			# Delete state from mute list
			mute_id = @redis.hget(key_state, :mute_id)
			if not mute_id.nil?
				@redis.srem("mute:#{mute_id}:states", key_state)

				# Delete mute if not used anymore
				if @redis.scard("mute:#{mute_id}:states") == 0
					delete_mute(mute_id)
				end
			end
			
			@redis.del(key_state)
		end

		def handle_event(event)
			data = JSON.parse(event, :symbolize_names => true)
			debug "[REDIS] Received event #{data}"

			case data[:event]
				when "device_added"
					device = data[:device]
					raise MessageCorruptedError, "#{data}" if device.nil?

					info "[REDIS] Notified of new device: #{device}"
					Celluloid::Actor[:assets].async.add_device(device)
					Celluloid::Actor[:workers].async.add_device(device)
				when "device_deleted"
					device = data[:device]
					raise MessageCorruptedError, "#{data}" if device.nil?

					info "[REDIS] Notified of device deleted: #{device}"
					Celluloid::Actor[:assets].async.delete_device(device)
					Celluloid::Actor[:workers].async.delete_device(device)
			end

		rescue JSON::ParserError, MessageCorruptedError => e
			warn "[REDIS] Received corrupted message: #{e}"
		end
end

class Database::MessageCorruptedError < RuntimeError
end

# vim: ts=4:sw=4:ai:noet
