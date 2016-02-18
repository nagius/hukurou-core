

module Hukurou
	module Core
		class Signals
			include Celluloid
			include Celluloid::Internals::Logger

			def initialize()
				@queue = []
				Thread.main[:shutdown] = false

				async.setup
			end

			private

				def handle(sig)
					info "[SIGNALS] Signal #{sig} received."
					case sig
						when :HUP
							Celluloid::Actor[:assets].reload()
							Celluloid::Actor[:workers].restart_all_workers()
						when :INT, :TERM
							Thread.main[:shutdown] = true

							info "[SIGNALS] Shutting down application. Please wait..."
							Celluloid.shutdown_timeout = 5
							Celluloid.shutdown
					end
				end	

				def setup()

					[:HUP, :INT, :TERM].each do |sig|
						trap(sig) do
							@queue << sig
						end
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
