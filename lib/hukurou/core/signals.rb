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
