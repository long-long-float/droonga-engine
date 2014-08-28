# Copyright (C) 2014 Droonga Project
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License version 2.1 as published by the Free Software Foundation.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

require "json"

require "droonga/path"
require "droonga/serf"
require "droonga/node_status"
require "droonga/catalog_generator"
require "droonga/catalog_modifier"
require "droonga/catalog_fetcher"
require "droonga/data_absorber"
require "droonga/safe_file_writer"

module Droonga
  module Command
    module Remote
      class Base
        attr_reader :response

        def initialize(serf_name, params)
          @serf_name = serf_name
          @params    = params
          @response  = {
            "log" => []
          }
        end

        def process
          # override me!
        end

        def should_process?
          for_me? or @params.nil? or not @params.include?("node")
        end

        private
        def node
          @serf_name
        end

        def host
          node.split(":").first
        end

        def target_node
          @params && @params["node"]
        end

        def for_me?
          target_node == @serf_name
        end

        def log(message)
          @response["log"] << message
        end
      end

      class ChangeRole < Base
        def process
          NodeStatus.new.set(:role, @params["role"])
        end
      end

      class ReportStatus < Base
        def process
          @response["value"] = NodeStatus.new.get(@params["key"])
        end
      end

      class Join < Base
        def process
          log("type = #{type}")
          case type
          when "replica"
            join_as_replica
          end
        end

        private
        def type
          @params["type"]
        end

        def source_node
          @params["source"]
        end

        def joining_node
          @params["node"]
        end

        def dataset_name
          @params["dataset"]
        end

        def valid_params?
          have_required_params? and
            valid_node?(source_node) and
            valid_node?(joining_node)
        end

        def have_required_params?
          required_params = [
            source_node,
            joining_node,
            dataset_name,
          ]
          required_params.all? do |param|
            not param.nil?
          end
        end

        NODE_PATTERN = /\A([^:]+):(\d+)\/(.+)\z/

        def valid_node?(node)
          node =~ NODE_PATTERN
        end

        def source_host
          @source_host ||= (source_node =~ NODE_PATTERN && $1)
        end

        def joining_host
          @source_host ||= (joining_node =~ NODE_PATTERN && $1)
        end

        def port
          @port ||= (source_node =~ NODE_PATTERN && $2 && $2.to_i)
        end

        def tag
          @tag ||= (source_node =~ NODE_PATTERN && $3)
        end

        def should_absorb_data?
          @params["copy"]
        end

        def join_as_replica
          return unless valid_params?

          log("source_node  = #{source_node}")

          other_hosts = replica_hosts
          return if other_hosts.empty?

          # restart self with the fetched catalog.
          SafeFileWriter.write(Path.catalog, JSON.pretty_generate(catalog))

          absorb_data if should_absorb_data?

          log("joining to the cluster: update myself")

          CatalogModifier.modify do |modifier|
            modifier.datasets[dataset_name].replicas.hosts += other_hosts
            modifier.datasets[dataset_name].replicas.hosts.uniq!
          end

          Serf.join(@serf_name, *other_hosts)
        end

        def replica_hosts(catalog=nil)
          catalog ||= fetch_catalog

          generator = CatalogGenerator.new
          generator.load(catalog)
          dataset = generator.dataset_for_host(source_host) ||
                      generator.dataset_for_host(host)
          return [] unless dataset
          dataset.replicas.hosts
        end

        def fetch_catalog
          fetcher = CatalogFetcher.new(:host          => source_host,
                                       :port          => port,
                                       :tag           => tag,
                                       :receiver_host => joining_host)
          fetcher.fetch(:dataset => dataset_name)
        end

        def absorb_data
          log("starting to copy data from #{source_host}")

          CatalogModifier.modify do |modifier|
            modifier.datasets[dataset_name].replicas.hosts = [host]
          end
          sleep(5) #TODO: wait for restart. this should be done more safely, to avoid starting of absorbing with old catalog.json.

          status = NodeStatus.new
          status.set(:absorbing, true)
          DataAbsorber.absorb(:dataset          => dataset_name,
                              :source_host      => source_host,
                              :destination_host => joining_host,
                              :port             => port,
                              :tag              => tag)
          status.delete(:absorbing)
          sleep(1)
        end
      end

      class AbsorbData < Base
        attr_writer :dataset_name, :port, :tag

        def process
          return unless source

          log("start to absorb data from #{source}")

          if dataset_name.nil? or port.nil? or tag.nil?
            current_catalog = JSON.parse(Path.catalog.read)
            generator = CatalogGenerator.new
            generator.load(current_catalog)

            dataset = generator.dataset_for_host(source)
            return unless dataset

            self.dataset_name = dataset.name
            self.port         = dataset.replicas.port
            self.tag          = dataset.replicas.tag
          end

          log("dataset = #{dataset_name}")
          log("port    = #{port}")
          log("tag     = #{tag}")

          status = NodeStatus.new
          status.set(:absorbing, true)
          DataAbsorber.absorb(:dataset          => dataset_name,
                              :source_host      => source,
                              :destination_host => host,
                              :port             => port,
                              :tag              => tag,
                              :client           => "droonga-send")
          status.delete(:absorbing)
        end

        private
        def source
          @params["source"]
        end

        def dataset_name
          @dataset_name ||= @params["dataset"]
        end

        def port
          @port ||= @params["port"]
        end

        def tag
          @tag ||= @params["tag"]
        end
      end

      class ModifyReplicasBase < Base
        private
        def dataset
          @params["dataset"]
        end

        def hosts
          @hosts ||= prepare_hosts
        end

        def prepare_hosts
          hosts = @params["hosts"]
          return nil unless hosts
          hosts = [hosts] if hosts.is_a?(String)
          hosts
        end
      end

      class SetReplicas < ModifyReplicasBase
        def process
          return unless dataset
          return unless hosts

          log("new replicas: #{hosts.join(",")}")

          CatalogModifier.modify do |modifier|
            modifier.datasets[dataset].replicas.hosts = hosts
          end

          Serf.join(@serf_name, *hosts)
          #XXX Now we should restart serf agent to remove unjoined nodes from the list of members...
        end
      end

      class AddReplicas < ModifyReplicasBase
        def process
          return unless dataset
          return unless hosts

          hosts -= [host]
          return if hosts.empty?

          log("adding replicas: #{hosts.join(",")}")

          CatalogModifier.modify do |modifier|
            modifier.datasets[dataset].replicas.hosts += hosts
            modifier.datasets[dataset].replicas.hosts.uniq!
          end

          Serf.join(@serf_name, *hosts)
        end
      end

      class RemoveReplicas < ModifyReplicasBase
        def process
          return unless dataset
          return unless hosts

          log("removing replicas: #{hosts.join(",")}")

          CatalogModifier.modify do |modifier|
            modifier.datasets[dataset].replicas.hosts -= hosts
          end

          #XXX Now we should restart serf agent to remove unjoined nodes from the list of members...
        end
      end

      class UpdateLiveNodes < Base
        def process
          def live_nodes
            Serf.live_nodes(@serf_name)
          end

          def output_live_nodes
            path = Path.live_nodes
            nodes = live_nodes
            file_contents = JSON.pretty_generate(nodes)
            SafeFileWriter.write(path, file_contents)
          end
        end
      end
    end
  end
end