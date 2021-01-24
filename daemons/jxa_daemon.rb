#!/usr/bin/env ruby

# frozen_string_literal: true

require 'oj'
require 'pty'
require 'socket'

Oj.default_options = { mode: :compat }

SOCKET_PATH = '/tmp/jxa-daemon.sock'

module JXADaemon # :nodoc:
  class Code # :nodoc:
    class << self
      def call(code)
        new(code).runnable_code
      end
    end

    def initialize(code)
      @raw_code = code
    end

    def runnable_code
      if raw_code?
        "(() => { #{@raw_code}; })()"
      else
        "(() => { #{code}; return run(#{args}) })()"
      end
    end

    private

    def options
      @options ||= begin
                     Oj.load(@raw_code, symbol_keys: true)
                   rescue StandardError
                     {}
                   end
    end

    def code
      @code ||= options[:code]
    end

    def args
      @args ||= options[:args] || []
    end

    def raw_code?
      !options.is_a?(Hash) || options.empty?
    end
  end

  class Runner # :nodoc:
    class << self
      def instance
        @instance ||= new
      end

      def call(code)
        instance.exec(code)
      end

      def cleanup
        instance.cleanup
      end
    end

    def initialize
      @reader, osa_out = PTY.open
      osa_in, @writer = IO.pipe

      @pid = spawn('osascript -l JavaScript -i -ss', in: osa_in, out: osa_out)
      [osa_in, osa_out].each(&:close)
    end

    def exec(code)
      @writer.puts(Code.call(code))
      @reader.gets[3..-1].rstrip
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
        code = s.recv(2**16)
        s.puts(Runner.call(code))
        s.close
      end
    rescue Errno::EPIPE
      retry
    end

    def setup
      Signal.trap(:TERM) { Runner.cleanup }
    end
  end
end

JXADaemon::Daemon.run!
