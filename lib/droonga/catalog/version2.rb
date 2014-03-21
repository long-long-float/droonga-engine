# Copyright (C) 2013-2014 Droonga Project
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
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

require "droonga/catalog/base"
require "droonga/catalog/dataset"
require "droonga/catalog/version2_validator"

module Droonga
  module Catalog
    class Version2 < Base
      def initialize(data, path)
        super
        validate
        prepare_data
      end

      def datasets
        @datasets
      end

      def slices(name)
        device = "."
        pattern = Regexp.new("^#{name}\.")
        results = {}
        @datasets.each do |dataset_name, dataset|
          n_workers = dataset.n_workers
          plugins = dataset.plugins
          dataset.replicas.each do |volume|
            volume.slices.each do |slice|
              volume_address = slice.volume.address
              if pattern =~ volume_address
                path = File.join([device, $POSTMATCH, "db"])
                path = File.expand_path(path, base_path)
                options = {
                  :dataset => dataset_name,
                  :database => path,
                  :n_workers => n_workers,
                  :plugins => plugins
                }
                results[volume_address] = options
              end
            end
          end
        end
        results
      end

      def get_routes(name, args)
        routes = []
        dataset = dataset(name)
        case args["type"]
        when "broadcast"
          volumes = dataset.replicas.select(args["replica"].to_sym)
          volumes.each do |volume|
            slices = select_slices(volume)
            slices.each do |slice|
              routes << slice["volume"]["address"]
            end
          end
        when "scatter"
          volumes = dataset.replicas.select(args["replica"].to_sym)
          volumes.each do |volume|
            dimension = volume.dimension
            key = args["key"] || args["record"][dimension]
            slice = select_slice(volume, key)
            routes << slice["volume"]["address"]
          end
        end
        routes
      end

      private
      def validate
        validator = Version2Validator.new(@data, @path)
        validator.validate
      end

      def prepare_data
        @datasets = {}
        @data["datasets"].each do |name, dataset|
          replicas = dataset["replicas"]
          replicas.each do |replica|
            total_weight = compute_total_weight(replica)
            continuum = []
            slices = replica["slices"]
            n_slices = slices.size
            slices.each do |slice|
              weight = slice["weight"] || default_weight
              points = n_slices * 160 * weight / total_weight
              points.times do |point|
                hash = Digest::SHA1.hexdigest("#{name}:#{point}")
                continuum << [hash[0..7].to_i(16), slice]
              end
            end
            replica["continuum"] = continuum.sort do |a, b|
              a[0] - b[0]
            end
          end
          @datasets[name] = Dataset.new(name, dataset)
        end
      end

      def default_weight
        1
      end

      def compute_total_weight(replica)
        slices = replica["slices"]
        slices.reduce(0) do |result, slice|
          result + (slice["weight"] || default_weight)
        end
      end

      def select_slices(volume, range=0..-1)
        sorted_slices = volume.slices.sort_by do |slice|
          slice.label
        end
        sorted_slices[range]
      end

      def select_slice(volume, key)
        continuum = volume["continuum"]
        return volume.slices.first unless continuum

        hash = Zlib.crc32(key)
        min = 0
        max = continuum.size - 1
        while (min < max)
          index = (min + max) / 2
          value, key = continuum[index]
          return key if value == hash
          if value > hash
            max = index
          else
            min = index + 1
          end
        end
        continuum[max][1]
      end
    end
  end
end
