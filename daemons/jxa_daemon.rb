#!/usr/bin/env ruby

# frozen_string_literal: true

require 'delegate'
require 'pty'
require 'socket'

require 'oj'
Oj.default_options = { mode: :compat }

module JXADaemon
  SOCKET_PATH = '/tmp/jxa-daemon.sock'

  using(Module.new do
    refine Numeric do
      def megabytes
        self * 1024 * 1024
      end
    end
  end)

  module PS
    module_function

    def rss_bytes(pid)
      `ps -o 'rss=' -p #{pid.to_i}`.strip.to_i * 1024
    end
  end

  class Code
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

  class ExpirableRunner < SimpleDelegator
    MEMORY_LIMIT = ENV.fetch('JXA_MEMORY_LIMIT', 64).to_i.megabytes

    def call(code)
      super.tap do
        cleanup if memory_limit_exceed?
      end
    end

    private

    def memory_limit_exceed?
      PS.rss_bytes(pid) > MEMORY_LIMIT
    end
  end

  class Runner
    attr_reader :pid

    class << self
      def instance
        @instance ||= new
      end

      def call(code)
        instance.exec(code)
      end

      def pid
        instance.pid
      end

      def cleanup
        instance.cleanup.tap { @instance = nil }
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
      return unless pid

      Process.detach(pid)
      Process.kill(:TERM, pid).tap do
        @reader&.close
        @writer&.close
        @pid = nil
      end
    end
  end

  module Daemon
    module_function

    def run!(socket_path = SOCKET_PATH)
      setup
      Socket.unix_server_loop(socket_path) do |s, _c|
        code = s.recv(2**16)
        s.puts(runner.call(code))
        s.close
      end
    rescue Errno::EPIPE
      retry
    end

    def setup
      Signal.trap(:TERM) { runner.cleanup }
    end

    def runner
      @runner ||= ExpirableRunner.new(Runner)
    end
  end
end

JXADaemon::Daemon.run!
