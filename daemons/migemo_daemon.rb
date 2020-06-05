#!/usr/bin/env ruby

# frozen_string_literal: true

require 'pty'
require 'socket'

SOCKET_PATH = '/tmp/migemo-daemon.sock'

module MigemoDaemon # :nodoc:
  class Runner # :nodoc:
    class << self
      def instance
        @instance ||= new
      end

      def call(pattern)
        instance.exec(pattern)
      end

      def bootstrap
        instance.bootstrap
      end

      def cleanup
        instance.cleanup
      end
    end

    def initialize
      @reader, migemo_out = PTY.open
      migemo_in, @writer = IO.pipe

      @pid = spawn('cmigemo -q', in: migemo_in, out: migemo_out)
      [migemo_in, migemo_out].each(&:close)
    end

    def exec(pattern)
      @writer.puts(pattern)
      @reader.gets.rstrip
    end

    def bootstrap
      @bootstrap ||= exec('')
    end

    def cleanup
      Process.kill(:TERM, @pid) if @pid
    end
  end

  module Daemon # :nodoc:
    module_function

    def run!(socket_path = SOCKET_PATH)
      setup
      Socket.unix_server_loop(socket_path) do |s, _c|
        pattern = s.recv(2**16)
        s.puts(Runner.call(pattern))
        s.close
      end
    rescue Errno::EPIPE
      retry
    end

    def setup
      Signal.trap(:TERM) { Runner.cleanup }
      Runner.bootstrap
    end
  end
end

MigemoDaemon::Daemon.run!
