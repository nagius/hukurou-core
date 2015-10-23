
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
			if @deferred_status.nil? or @deferred_status == :unknown
				callback {
					begin
						@errbacks.pop unless @errbacks.nil?
						succeed(success.call(*@deferred_args))
					rescue StandardError => e
						fail(e)
					end
				}
				errback {
					begin
						@callbacks.pop unless @callbacks.nil?
						succeed(error.call(*@deferred_args))
					rescue StandardError => e
						fail(e)
					end
				}
			else
				# Run the corresponding block immediately if the Defer has already been fired
				block = @deferred_status == :succeeded ? success : error
				begin
					succeed(block.call(*@deferred_args))
				rescue StandardError => e
					fail(e)
				end
			end
		end

		def maybe_deferred
			raise NotImplementedError
		end

		def chain_deferred(d)
			raise NotImplementedError
		end

	end

	class DefaultDeferrable
		def self.failed(*args)
			d = new
			d.fail(*args)
			return d
		end
	
		def self.succeeded(*args)
			d = new
			d.succeed(*args)
			return d
		end
	end

	class DeferrableList
		include Deferrable

		def initialize(deferrables)
			@results = []
			@results_count = deferrables.size

			if @results_count == 0
				succeed([]) # Fire immediately if no deferrable provided
			else
				# TODO: manage error handling
				deferrables.each { |deferrable| 
					deferrable.add_callback { |result|
						@results << result
						@results_count -= 1

						if @results_count <= 0
							succeed(@results)
						end
					}
				}
			end
		end
	end
end

# vim: ts=4:sw=4:ai:noet
