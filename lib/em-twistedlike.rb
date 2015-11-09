
# This Monkeypatch implement some of Twisted's defer funtionnalities to EventMachine Deferrable
# which provide a better exception management during callbacks execution
#
# For more information, see
# http://twistedmatrix.com/documents/12.0.0/core/howto/defer.html

module EventMachine
	# Wrap the defer into a Deferrable with exception handling
	def self.defer_to_thread(&block)
		d=EM::DefaultDeferrable.new

		operation = proc {
			begin
				block.call
			rescue StandardError => e
				d.fail(e)
			end
		}

		EM.defer(operation, proc { |result| d.succeed(result) })

		return d
	end

	module Deferrable
		def add_callback(&block)
			add_callbacks(block, proc { |args| args })
		end

		def add_errback(&block)
			add_callbacks(proc { |args| args }, block)
		end

		def add_both(&block)
			add_callbacks(block, block)
		end

		def add_callbacks(success, error)
			def call(block)
				begin
					result = block.call(*@deferred_args)
					if result.kind_of? Exception
						fail(result)
					else
						succeed(result)
					end
				rescue StandardError => e
					fail(e)
				end
			end

			if @deferred_status.nil? or @deferred_status == :unknown
				callback {
					@errbacks.pop unless @errbacks.nil?
					call(success)
				}
				errback {
					@callbacks.pop unless @callbacks.nil?
					call(error)
				}
			else
				# Run the corresponding block immediately if the Defer has already been fired
				call(@deferred_status == :succeeded ? success : error)
			end
		end
		
		# Trigger the errback chain with wrapping the arg in an Exception if not one
		# Named tfail() "twisted-fail" to not interfere with other libraries
		def tfail reason
			if not reason.kind_of? Exception
				reason = RuntimeError.new(reason)
			end
			fail(reason)
		end

		def maybe_deferred
			raise NotImplementedError
		end

		def chain_deferred(d)
			raise NotImplementedError
		end

	end

	class DefaultDeferrable
		include Deferrable

		def self.failed(args)
			d = new
			d.tfail(args)
			return d
		end
	
		def self.succeeded(args)
			d = new
			d.succeed(args)
			return d
		end
	end

	# See https://twistedmatrix.com/documents/current/api/twisted.internet.defer.DeferredList.html
	class DeferrableList
		include Deferrable

		def initialize(deferrables)
			@results = []
			@results_count = deferrables.size

			if @results_count == 0
				succeed([]) # Fire immediately if no deferrable provided
			else
				deferrables.each_with_index { |deferrable, index| 
					deferrable.add_callbacks( proc { |result|
						@results[index] = [true, result]
						result
					}, proc { |reason|
						@results[index] = [false, reason]
						reason
					})

					deferrable.add_both { |result|
						@results_count -= 1  
						succeed(@results) if @results_count <= 0
						result
					}
				}
			end
		end
	end
end

# vim: ts=4:sw=4:ai:noet
