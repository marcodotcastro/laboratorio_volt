# frozen_string_literal: true

require "open3"
require "json"
require "shellwords"
require "time"

module Vdd
  CommandResult = Data.define(:stdout, :stderr, :status, :duration) do
    def success?
      status == 0
    end
  end

  module Runner
    module_function

    def run(argv, chdir: nil, env: {}, logger: nil, stdin_data: nil, on_event: nil)
      command = Array(argv)
      raise ArgumentError, "Command must be a non-empty argument array" if command.empty? || command.any? { |argument| !argument.is_a?(String) }

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = run_with_events(command, env, chdir, stdin_data, on_event)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      result = CommandResult.new(stdout: stdout, stderr: stderr, status: status.exitstatus, duration: duration)
      logger&.command(command, stdout: stdout, stderr: stderr, status: result.status, duration: duration, env: env)
      result
    rescue Errno::ENOENT => error
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      result = CommandResult.new(stdout: "", stderr: error.message, status: 127, duration: duration)
      logger&.command(command, stdout: "", stderr: error.message, status: 127, duration: duration, env: env)
      result
    end

    def run_with_events(command, env, chdir, stdin_data, on_event)
      options = {}
      options[:chdir] = chdir if chdir
      Open3.popen3(env, *command, **options) do |input, output, error, wait_thread|
        stdout_reader = Thread.new { output.read }
        stderr_reader = Thread.new do
          error.each_line.with_object(String.new) do |line, buffer|
            parsed = on_event && parse_event_line(line)
            if parsed
              on_event.call(**parsed)
            else
              buffer << line
            end
          end
        end
        input_error = nil
        input_writer = Thread.new do
          begin
            input.write(stdin_data) if stdin_data
          rescue Errno::EPIPE, IOError
            nil
          rescue StandardError => error
            input_error = error
          ensure
            input.close unless input.closed?
          end
        end
        status = wait_thread.value
        input_writer.join
        raise input_error if input_error
        [stdout_reader.value, stderr_reader.value, status]
      end
    end

    def parse_event_line(line)
      return unless line.start_with?("VDD_EVENT ")

      payload = line.delete_prefix("VDD_EVENT ").strip
      fields = Shellwords.split(payload)
      values = fields.each_with_object({}) do |field, parsed|
        key, value = field.split("=", 2)
        return unless key && value

        parsed[key] = value
      end
      raw_details = payload[/\bdetails=(\{.*\})\s*\z/, 1]
      values["details"] = raw_details if raw_details && valid_json?(raw_details)
      allowed_keys = %w[event action status message details duration]
      return unless (values.keys - allowed_keys).empty?
      return unless %w[start progress success warning error finish].include?(values["event"])
      return unless %w[event action status message].all? { |key| values.key?(key) }

      values[:duration] = values.delete("duration").to_f if values.key?("duration")
      if values.key?("details")
        values[:details] = JSON.parse(values.delete("details"))
      end
      values.transform_keys!(&:to_sym)
      values
    rescue ArgumentError, JSON::ParserError
      nil
    end

    def valid_json?(value)
      JSON.parse(value)
      true
    rescue JSON::ParserError
      false
    end
  end
end
