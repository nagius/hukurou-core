#!/usr/bin/env ruby

require 'eventmachine'
require 'cassandra'

# TODO: add check for DC and state fields
# TODO: better error management
# TODO: check error handling when db is down

class Database

	ST_OK = "green"
	ST_WARN = "yellow"
	ST_ERR = "red"

	def initialize
		# Open connection to Cassandra
		# TODO: check failover policie
		@cluster = Cassandra.cluster(
			hosts: $CFG[:database][:hosts],
			retry_policy: Cassandra::Retry::Policies::Default.new,
		)

		@session = @cluster.connect($CFG[:database][:keyspace])
	
		# Prepare all statements
		@st=Hash.new
		@st[:all_states] = @session.prepare("select device from states")
		@st[:states_by_service] = @session.prepare("SELECT state from states where device = ? and service = ?")
		@st[:insert_state] = @session.prepare("INSERT INTO states (device, service, state, message, starts_at, last_seen, acked, disabled) VALUES (?, ?, ?, ?, toTimestamp(now()), toTimestamp(now()), False, False)")
		@st[:insert_dc] = @session.prepare("INSERT INTO devices_by_dc (device, dc) VALUES (?, ?)")
		@st[:insert_history] = @session.prepare("INSERT INTO history (uuid, device, service, state, message) VALUES (now(), ?, ?, ?, ?)")
		@st[:update_same_state] = @session.prepare("UPDATE states SET message = ?, last_seen=toTimestamp(now()) WHERE device = ? and service = ?")
		@st[:update_change_state] = @session.prepare("UPDATE states SET state = ?, message = ?, starts_at=toTimestamp(now()), last_seen=toTimestamp(now()), acked=False WHERE device = ? and service = ?")
		@st[:ack_state] = @session.prepare("UPDATE states SET acked = True, ack_message = ?, ack_user = ? WHERE device = ? and service = ?")
		@st[:devices_by_dc] = @session.prepare("select device from devices_by_dc where dc = ?")
		@st[:states_by_device] = @session.prepare("select * from states where device = ?")
		@st[:delete_state] = @session.prepare("delete from states where device = ?")
		@st[:delete_device] = @session.prepare("delete from devices_by_dc where device = ? and dc = ?")
		@st[:update_maintenance_state] = @session.prepare("UPDATE states SET disabled = ? WHERE device = ? and service = ?")
	end

	def get_all_devices()
		# Using defer and synchonous call because Cassandra's async doesn't work well with Eventmachine
		EM.defer_to_thread {
			result = @session.execute(@st[:all_states])
			result.map { |x| x['device'] }
		}
	end

	def save_state(device, service, state, message)
		# Convert to string 'cause it can also be a symbol
		service = service.to_s
		$log.debug "[CASSANDRA] Saving state #{[device, service, state, message, $CFG[:dc]]}"

		EM.defer_to_thread {
			is_new=false # Flag to detect new device

			# Get current state
			res=@session.execute(@st[:states_by_service] , arguments: [device, service])
			if res.empty?
				# New device
				is_new=true
				@session.execute(@st[:insert_state], arguments: [device, service, state, message])
				@session.execute(@st[:insert_dc], arguments: [device, $CFG[:dc]])
				@session.execute(@st[:insert_history], arguments: [device, service, state, message]) # TODO: set TTL
				
			elsif res.first['state'] == state
				# Same state
				@session.execute(@st[:update_same_state], arguments: [message, device, service])
			else	
				# State change
				@session.execute(@st[:update_change_state], arguments: [state, message, device, service])
				@session.execute(@st[:insert_history], arguments: [device, service, state, message]) # TODO: set TTL
			end
				
			is_new
		}
	end

	def ack_state(device, service, message, user)
		$log.debug "[CASSANDRA] Ack #{device}, #{service}, #{message}, #{user}"
		EM.defer_to_thread {
			@session.execute(@st[:ack_state], arguments: [message, user, device, service])
		}
	end

	def get_devices()
		# Use EM defer instead of Cassandra's async to return list instead of Cassandra::Result
		EM.defer_to_thread {
			result = @session.execute(@st[:devices_by_dc], arguments: [$CFG[:dc]])
			result.map { |x| x['device'] }
		}
	end
	
	def get_state(device)
		EM.defer_to_thread {
			result = @session.execute(@st[:states_by_device], arguments: [device])
			result.to_a
		}
	end

	def delete_device(device)
		$log.debug "[CASSANDRA] Delete #{device}"

		# Do not delete history, will use TTL
		d=EM.defer_to_thread {
			@session.execute(@st[:delete_state], arguments: [device])
			@session.execute(@st[:delete_device], arguments: [device, $CFG[:dc]])
		}
		d.errback { |e|
			$log.error "[CASSANDRA] Failed to delete device: #{e}"
		}
		return d # TODO: factorise
	end

	def add_maintenance(device, service, starts_at, ends_at, message, user)
		$log.debug "[CASSANDRA] New maintenance #{device}, #{service}, #{starts_at}, #{ends_at}, #{message}, #{user}"
		# FIXME: This is a bug in Cassandra driver with timestamp and prepared statement. Try with Cassandra::Types::Timestamp ??
		#   add = session.prepare("insert into maintenances (uuid, device, service, starts_at, ends_at, message, user) VALUES (now(), ?, ?, ?, ?, ?, ?)")
		#   session.execute(add, arguments: [device, service, '2015-07-30 11:11:05+0000', '2015-07-30 11:11:05+0000', message, user])
		EM.defer_to_thread {
			@session.execute("insert into maintenances (uuid, device, service, starts_at, ends_at, message, user) VALUES (now(), '#{device}', '#{service}', '#{starts_at}', '#{ends_at}', '#{message}', '#{user}')")
		}
	end

	def apply_maintenance(device, service, starts_at, ends_at)
		now = Time.now()
		starts = Time.parse(starts_at)
		ends = Time.parse(ends_at)

		$log.debug "[CASSANDRA] Apply maintenance #{[device, service, starts_at, ends_at]}"

		EM.defer_to_thread {
			@session.execute(@st[:update_maintenance_state], arguments: [(starts < now and now < ends), device, service])
		}
	end
end

# vim: ts=4:sw=4:ai:noet
