# TODO: document datamodel
# TODO: YARD documentation

# TODO: add history on pub/sub change state ?

require 'celluloid/current'
require "redis"
require "hiredis"
require "json"

class Database
    include Celluloid
	include Celluloid::Internals::Logger
	finalizer :shutdown

	class State
		OK = "OK"
		ERR = "ERROR"
		WARN = "WARN"
		STALE = "STALE"
	end

	def initialize()
		@redis = Redis.new($CFG[:database])

		# Check mimium version (needed for *scan features)
		if @redis.info["redis_version"] < "2.8.0"
			abort "Redis version must be >= 2.8.0"
		end
	end

	def shutdown()
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
			@redis.pipelined do
				@redis.mapped_hmset(key_state, data)
				@redis.sadd("devices", device)
				# TODO: add history
			end
			# TODO: pub/sub new device
			debug("[REDIS] New device detected: #{device}")
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
	end

	def set_stale_state(device, service)
		key_state = "state:#{device}:#{service}"

		if @redis.hget(key_state, :state) != State::STALE
			debug "[REDIS] State flagged as stale: #{device}:#{service}"
			@redis.hmset(key_state, :state, State::STALE, :starts_at, Time.now.to_i)
			cancel_ack(key_state)
			state_changed(key_state)
		end
	end

	def get_state(device, service)
		key_state = "state:#{device}:#{service}"

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
	end

	def get_devices()
		@redis.smembers("devices")
	end

	def get_states()
		@redis.scan_each(:match => "state:*").map { |key|
			device, service = key.split(":")[1,2]
			{ :device => device, :service => service }
		}
	end

	def delete_device(device)
		debug("[REDIS] Delete device: #{device}")

		@redis.srem("devices", device)

		# WARNING: *scan do not work inside a pipeline or a multi
		@redis.scan_each(:match => "state:#{device}:*") { |key_state|
			delete_state_by_key(key_state)
		}

		@redis.zscan_each("last_seens", :match => "#{device}:*") { |key|
			@redis.zrem("last_seens", key[0])
		}
	end

	def delete_state(device, service)
		debug("[REDIS] Delete state: #{device}:#{service}")
		delete_state_by_key("state:#{device}:#{service}")
	end

	def ack_state(device, service, message, user)
		key_state = "state:#{device}:#{service}"

		if @redis.hget(key_state, :ack_id).nil? # Do nothing if already acked
			debug("[REDIS] Acknowledge state: #{device}:#{service}")
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

		debug("[REDIS] Added mute: #{devices}:#{services} by #{user} from #{starts_at} to #{ends_at}")
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
		debug("[REDIS] Mute ##{id} deleted")

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
			# TODO: pub/sub change state
			debug("[REDIS] State change for #{key_state}")
		end

		def cancel_ack(key_state)
			ack_id = @redis.hget(key_state, :ack_id)
			if not ack_id.nil?
				debug("[REDIS] Acknowledge ##{ack_id} cancelled for #{key_state}")
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
end

# vim: ts=4:sw=4:ai:noet
