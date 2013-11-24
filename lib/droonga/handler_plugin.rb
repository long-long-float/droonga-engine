# -*- coding: utf-8 -*-
#
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

require "droonga/plugin_registerable"

module Droonga
  class HandlerPlugin
    extend PluginRegisterable

    def initialize(handler)
      @handler = handler
      @context = @handler.context
    end

    def envelope
      @handler.envelope
    end

    def shutdown
    end

    def handlable?(command)
      self.class.processable?(command)
    end

    def handle(command, request, *arguments)
      __send__(self.class.method_name(command), request, *arguments)
    rescue => exception
      Logger.error("error while handling #{command}",
                   request: request,
                   arguments: arguments,
                   exception: exception)
    end

    def emit(value, name=nil)
      @handler.emit(value, name)
    end

    def post(body, destination=nil)
      @handler.post(body, destination)
    end

    def prefer_synchronous?(command)
      false
    end
  end
end
