require 'stringio'
require 'tempfile'

module Nitra
  module Workers
    class Worker
      class << self

        @@worker_classes = {}

        def inherited(klass)
          @@worker_classes[klass.framework_name] = klass
        end

        def worker_classes
          @@worker_classes
        end

        ##
        # Return the framework name of this worker
        #
        def framework_name
          self.name.split("::").last.downcase
        end
      end

      class RetryException < Exception; end


      attr_reader :runner_id, :worker_number, :configuration, :channel, :io

      def initialize(runner_id, worker_number, configuration)
        @runner_id = runner_id
        @worker_number = worker_number
        @configuration = configuration
        @forked_worker_pid = nil

        ENV["TEST_ENV_NUMBER"] = worker_number.to_s

        # Frameworks don't like it when you change the IO between invocations.
        # So we make one object and flush it after every invocation.
        @io = StringIO.new
      end


      def fork_and_run
        client, server = Nitra::Channel.pipe

        pid = fork do
          # This is important. We don't want anything bubbling up to the master that we didn't send there.
          # We reopen later to get the output from the framework run.
          $stdout.reopen('/dev/null', 'a')
          $stderr.reopen('/dev/null', 'a')

          trap("USR1") { interrupt_forked_worker_and_exit }

          server.close
          @channel = client
          run
        end

        client.close

        [pid, server]
      end

      protected
      def load_environment
        raise 'Subclasses must implement this method.'
      end

      def minimal_file
        raise 'Subclasses must implement this method.'
      end

      def run_file(filename, preload = false)
        raise 'Subclasses must implement this method.'
      end

      def clean_up
        raise 'Subclasses must implement this method.'
      end

      def run
        trap("SIGTERM") do
          channel.write("command" => "error", "process" => "trap", "text" => 'Received SIGTERM', "on" => on)
          Process.kill("SIGKILL", Process.pid)
        end
        trap("SIGINT") do
          channel.write("command" => "error", "process" => "trap", "text" => 'Received SIGINT', "on" => on)
          Process.kill("SIGKILL", Process.pid) 
        end

        debug "Started, using TEST_ENV_NUMBER #{ENV['TEST_ENV_NUMBER']}"
        connect_to_database
        reset_cache

        preload_framework

        # Loop until our runner passes us a message from the master to tells us we're finished.
        loop do
          debug "Announcing availability"
          channel.write("command" => "ready", "framework" => self.class.framework_name, "worker_number" => worker_number)
          debug "Waiting for next job"
          data = channel.read
          if data.nil? || data["command"] == "close"
            debug "Channel closed, exiting"
            exit
          elsif data['command'] == "process"
            filename = data["filename"].chomp
            process_file(filename)
          end
        end
      rescue => e
        channel.write("command" => "error", "process" => "init framework", "text" => e.message, "on" => on)
      end

      def on
        "#{runner_id}:#{worker_number}"
      end

      def preload_framework
        debug "running empty spec/feature to make framework run its initialisation"
        file = Tempfile.new("nitra")
        begin
          load_environment
          file.write(minimal_file)
          file.close

          output = Nitra::Utils.capture_output do
            run_file(file.path, true)
          end

          channel.write("command" => "stdout", "process" => "init framework", "text" => output, "on" => on) unless output.empty?
        ensure
          file.close unless file.closed?
          file.unlink
          io.string = ""
        end
        clean_up
      end

      def connect_to_database
        if defined?(Rails)
          Nitra::RailsTooling.connect_to_database
          debug("Connected to database #{ActiveRecord::Base.connection.current_database}")
        end
      end

      def reset_cache
        Nitra::RailsTooling.reset_cache if defined?(Rails)
      end

      ##
      # Process the file, forking before hand.
      #
      # There's two sets of data we're interested in, the output from the test framework, and any other output.
      # 1) We capture the framework's output in the @io object and send that up to the runner in a results message.
      # This happens in the run_x_file methods.
      # 2) Anything else we capture off the stdout/stderr using the pipe and fire off in the stdout message.
      #
      def process_file(filename)
        debug "Starting to process #{filename}"
        start_time = Time.now

        stdout_pipe = IO.pipe
        stderr_pipe = IO.pipe
        @forked_worker_pid = fork do
          trap('USR1') { exit! }  # at_exit hooks will be run in the parent.
          $stdout.reopen(stdout_pipe[1])
          $stderr.reopen(stderr_pipe[1])

          $0 = filename
          run_file(filename)

          stdout_pipe.each(&:close)
          stderr_pipe.each(&:close)
          exit!  # at_exit hooks will be run in the parent.
        end
        stdout_pipe[1].close
        stderr_pipe[1].close
        stdout_text = stdout_pipe[0].read
        stderr_text = stderr_pipe[0].read
        Process.wait(@forked_worker_pid) if @forked_worker_pid
        @forked_worker_pid = nil

        end_time = Time.now
        channel.write("command" => "stdout", "process" => "test framework", "filename" => filename, "text" => stdout_text, "on" => on) unless stdout_text.empty?
        channel.write("command" => "stderr", "process" => "test framework", "filename" => filename, "text" => stderr_text, "on" => on) unless stderr_text.empty?
        debug "#{filename} processed in #{'%0.2f' % (end_time - start_time)}s"
      end


      ##
      # Interrupts the forked worker cleanly and exits
      #
      def interrupt_forked_worker_and_exit
        Process.kill('USR1', @forked_worker_pid) if @forked_worker_pid
        Process.waitall
        exit
      end

      ##
      # Sends debug data up to the runner.
      #
      def debug(*text)
        if configuration.debug
          channel.write("command" => "debug", "text" => text.join, "on" => on)
        end
      end
    end
  end
end
