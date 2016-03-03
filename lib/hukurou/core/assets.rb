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

# TODO: make default_device for each DC ??
# TODO: check default DC ?

# TODO: load only for the concerned DC ?
# TODO: use one repos for all DC or one repo for each dc ?

require 'tree'
require 'pathname'
require 'yaml'

module Hukurou
	module Core
		class Device
			include Celluloid::Internals::Logger

			attr_reader :path

			# Load the Device configuration from the assets tree definition
			#
			# @param file [Pathname] Specific YAML configuration file
			# @param services [Hash] Global services definition
			# @param default_config [Hash] Services config inherited from parent and merged with local config
			def initialize(file, services, default_config = {})
				@name = file.basename.to_s
				@path = file.dirname.relative_path_from(Pathname.new(Config[:assets])).to_s.split('/') 

				# Cleanup path from useless directory
				@path.reject! { |dir| dir == "." }
				
				# Load specific config and merge with default config
				@config = default_config
				begin
					local_config = YAML::load_file(file).deep_symbolize_keys
					if local_config
						# File is not empty
						@config = default_config.gentle_deep_merge(local_config)
					end
				rescue StandardError => e
					warn "[ASSETS] Can't parse YAML file #{file}: #{e}"
				end
				
				# Merge global services definition with local config
				if @config[:services].blank?
					warn "[ASSETS] Service definition is empty for #{file}"
				else
					@config[:services].keys.each do |service|
						# Ensure service configuration is not nil
						@config[:services][service] = Hash.new if @config[:services][service].nil?

						if not services[service].blank?
							# The local config has the priority
							@config[:services][service] = services[service].gentle_deep_merge(@config[:services][service])
						end

						# Check if service definition is present
						if @config[:services][service].blank?
							warn "[ASSETS] Definition of service #{service} is empty for #{file}, discarding..."
							@config[:services].delete(service)
							next
						end
					
						# Remove disabled services
						if @config[:services][service][:disabled]
							@config[:services].delete(service) 
							next
						end

						# Check mandatories values
						if not @config[:services][service].has_key?(:interval) or not @config[:services][service].has_key?(:command)
							warn "[ASSETS] Definition of service #{service} is incomplete for #{file}, interval or command is missing, discarding..."
							@config[:services].delete(service)
							next
						end
					end
				end

				# Precompile regex if any
				@regex=nil
				if @config[:regex]
					begin
						@regex=Regexp.new(@name)
					rescue RegexpError => e
						warn "[ASSETS] Invalid regex #{@name}: #{e}, discarding..."
					end
				end
			end

			# Tell if the Device name is a regex
			#
			# @return [Boolean]
			def is_regex?()
				!@regex.nil?
			end

			# Tell if the specific name match the regex
			#
			# @param name [String] Device name
			# @return [Boolean]
			def match?(name)
				@regex ? @regex =~ name : @name == name
			end

			# Return the DC of this Device (first level in the path)
			#
			# @return [String] DC name
			def get_dc
				@path[0]
			end
			
			# Return the merged services definition of this Device
			#
			# @return [Hash]
			def get_services()
				@config[:services]
			end
		end

		class Assets
			include Celluloid
			include Celluloid::Internals::Logger

			attr_reader :tree, :expanded_tree

			# Initialize and load the Assets definition tree
			def initialize()
				@default_device=nil
				@expanded_tree=nil

				async.reload
			end

			# Load the Assets definition tree
			def load_assets()
				begin
					@services = YAML::load_file(Config[:services][:definitions]).deep_symbolize_keys
				rescue Errno::ENOENT => e
					raise "Can't read file #{Config[:services][:definitions]}, check config variable :services : #{e}"
				end

				begin
					@tree = create_subtree(Pathname.new(Config[:assets]))
				rescue Errno::ENOENT => e
					raise "Can't parse directory #{Config[:assets]}, check config variable :assets : #{e}"
				end

				devices = Celluloid::Actor[:redis].get_devices()
				expand_tree(devices)
			end
			
			# Reload the Assets definition tree
			def reload()
				info "[ASSETS] Reloading assets..."
				begin
					load_assets()
				rescue StandardError => e
					error "[ASSETS] Failed to reload assets, system may be in an incoherent state : #{e}"
				end
			end

			# Create the tree populated with Device object
			#
			# @param path [Pathname] Root path of the tree
			# @param config [Hash] Inherited config from the parent
			# @return [TreeNode]
			def create_subtree(path, config = {})
				root = Tree::TreeNode.new(path.basename.to_s)
				files = path.children

				# Load default config and remove it from the tree
				files.reject! do |file| 
					if file.basename.to_s == "default.yml"
						begin
							# Create default device with root's default config
							if @default_device.nil?
								@default_device = Device.new(file, @services)
							end

							# Merge default config with parent's one
							config = config.gentle_deep_merge(YAML::load_file(file).deep_symbolize_keys)
						rescue StandardError => e
							warn "[ASSETS] Can't parse YAML file #{file}: #{e}"
						end
						true
					else
						false
					end
				end

				# Create next level
				files.each do |file|
					if file.directory?
						root << create_subtree(file, config)
					else
						root << Tree::TreeNode.new(file.basename.to_s, Device.new(file, @services, config))
					end
				end

				return root
			end

			# Search a Node in the tree by device name
			#
			# @param name [String] Device name
			# @return [TreeNode]
			def get_node(name)
				found=[]

				# Perform a depth-first search
				@tree.each_leaf do |node|
					if node.has_content? and node.content.match?(name)
						found << node
					end
				end
				
				if found.empty?
					return nil
				elsif found.size > 1
					# Give priority to explicit hostnames
					found.each { |node| return node if not node.content.is_regex? }
				end

				return found.first
			end

			# Get the services definiton for a specific device
			#
			# @param name [String] Device name
			# @return [Hash]
			def get_services(name)
				# Duplicate services hash to not modify original device object
				services = get_device_by_name(name).get_services().deep_dup

				services.each_value { |config|
					# Add hostname and expand variable
					config[:hostname] = name
					config[:command] = config[:command] % config
				}

				return services
			rescue KeyError => e
				msg = "Cannot expand variable for device #{name}: #{e}"

				warn "[ASSETS] #{msg}"
				abort SubstitutionError.new(msg)
			end

			# Search for a specific Device object 
			#
			# @param name [String] Device name
			# @return [Device]
			def get_device_by_name(name)
				node = get_node(name)
				return node.nil? ? @default_device : node.content
			end

			# Get the list of Devices' names in a specific directory
			#
			# @param path [Array<String>] Path as a list of directories
			# @return [Array<String>]
			def get_devices_by_path(path)
				# TODO: refactor this
				tree = @expanded_tree
				abort PathNotFoundError.new if tree.nil?

				# Walk down the tree
				path.each{ |dir| 
					tree = tree[dir] 
					abort PathNotFoundError.new if tree.nil?
				}

				# Get all direct elements
				tree.children.select { |node| node.content }.map(&:name)
			end

			# Get the content of a directory
			#
			# @param path [Array<String>] Path as a list of directories
			# @return [Array<Hash>] List of child elements
			def get_sub_dir(path)
				# TODO: refactor this
				tree = @expanded_tree

				# Walk down the tree
				path.each{ |dir| 
					tree = tree[dir] 
					abort PathNotFoundError.new if tree.nil?
				}

				# Get all direct elements
				tree.children.map { |node|
					{ :title => node.name , :folder => !node.content, :lazy => true }
				}
			end

			# Dump the directory structure as a nested list of hash
			#
			# @return [Array<Hash>]
			def get_directory_tree()
				def to_list_of_hash(children)
					dir = []
					children.each { |child|
						if child.content.nil? # Is a directory
							dir << { :title => child.name, :folder => true, :children => to_list_of_hash(child.children) }
						end
					}

					dir
				end

				to_list_of_hash(@tree.children)
			end

			# Replace config entities by list of running devices
			#
			# @param devices [Array<String>] List of devices' name
			def expand_tree(devices)
				debug "[ASSETS] Expanding device tree"
				
				# Duplicate the tree structure without devices (only directory)
				# TODO: optimize this
				@expanded_tree = @tree.dup
				@expanded_tree.each_leaf { |node|
					node.remove_from_parent! if node.has_content?
				}
				
				devices.each { |device|
					add_device(device)
				}
			end

			# Add a new running device to the expanded tree
			#
			# @param device [String] Device name
			def add_device(device)
				node = @expanded_tree

				get_device_by_name(device).path.each { |dir|
					# Walk down the tree
					node = node[dir]
				}
				node << Tree::TreeNode.new(device, true)
			rescue StandardError => e
				error "[ASSETS] Failed to add device: #{e}"
			end

			# Remove a dead device from the expanded tree
			#
			# @param device [String] Device name
			def delete_device(device)
				@expanded_tree.each { |node|
					if node.name == device
						node.remove_from_parent!
						return
					end
				}
			end

		end
	end
end

class Hukurou::Core::Assets::PathNotFoundError < StandardError
end

class Hukurou::Core::Assets::SubstitutionError < StandardError
end

# vim: ts=4:sw=4:ai:noet
