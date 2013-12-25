# Copyright (C) 2013 Droonga Project
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

module Droonga
  class Session
    def initialize(id, dispatcher, collector, tasks, inputs)
      @id = id
      @dispatcher = dispatcher
      @collector = collector
      @tasks = tasks
      @n_dones = 0
      @inputs = inputs
    end

    def done?
      @n_dones == @tasks.size
    end

    def start
      tasks = @inputs[nil]
      tasks.each do |task|
        local_message = {
          "id"   => @id,
          "task" => task,
        }
        @dispatcher.process_local_message(local_message)
        @n_dones += 1
      end
    end

    def receive(name, value)
      tasks = @inputs[name]
      unless tasks
        #TODO: result arrived before its query
        return
      end
      tasks.each do |task|
        task["n_of_inputs"] += 1
        component = task["component"]
        type = component["type"]
        command = "collector_" + type
        n_of_expects = component["n_of_expects"]
        message = {
          "task"=>task,
          "name"=>name,
          "value"=>value
        }
        @collector.process(command, message)
        return if task["n_of_inputs"] < n_of_expects
        #the task is done
        result = task["values"]
        post = component["post"]
        @dispatcher.reply(result) if post
        component["descendants"].each do |name, routes|
          message = {
            "id" => @id,
            "input" => name,
            "value" => result[name]
          }
          routes.each do |route|
            @dispatcher.dispatch(message, route)
          end
        end
        @n_dones += 1
      end
    end

    private
    def log_tag
      "session"
    end
  end
end