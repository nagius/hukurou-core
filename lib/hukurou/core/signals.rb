

module Hukurou
	module Core
		class Signals
			include Celluloid
			include Celluloid::Internals::Logger

			def initialize()
				@queue = []
				async.setup
			end

			private

				def handle(sig)
					info "[SIGNALS] Signal #{sig} received."
					case sig
						when :HUP
							Celluloid::Actor[:assets].reload()
							Celluloid::Actor[:workers].restart_all_workers()
					end
				end	

				def setup()

					trap(:HUP) do
						@queue << :HUP
					end

					every(1) {
						while sig = @queue.shift
							async.handle(sig)
						end
					}
				end

		end
	end
end


# vim: ts=4:sw=4:ai:noet
