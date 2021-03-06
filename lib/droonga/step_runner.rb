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

require "droonga/loggable"
require "droonga/plugin"
require "droonga/single_step"

module Droonga
  class StepRunner
    include Loggable

    def initialize(dataset, plugins)
      @dataset = dataset
      @definitions = {}
      plugins.each do |name|
        plugin = Plugin.registry[name]
        plugin.single_step_definitions.each do |definition|
          @definitions[definition.name] = definition
        end
      end
    end

    def shutdown
    end

    def plan(message)
      type = message["type"]
      logger.trace("plan: start",
                   :dataset => message["dataset"],
                   :type => type)
      definition = find(type)
      if definition.nil?
        raise UnsupportedMessageError.new(:planner, message)
      end
      step = SingleStep.new(@dataset, definition)
      plan = step.plan(message)
      logger.trace("plan: done",
                   :dataset => message["dataset"],
                   :type => type)
      plan
    end

    def find(type)
      @definitions[type]
    end

    private
    def log_tag
      "step-runner"
    end
  end
end
