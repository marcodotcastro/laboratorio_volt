# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "shellwords"
require "securerandom"
require "time"

module Vdd
  module Logging
    SENSITIVE_NAME = /(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTHORIZATION|API[_-]?KEY|PRIVATE[_-]?KEY|COOKIE)/i
    INLINE_SECRET = /((?:--?)?(?:token|secret|password|passwd|credential|authorization|api[_-]?key|private[_-]?key|cookie)\b\s*[=:]\s*)([^\s,;}\]]+)/i

    class Log
      attr_reader :path

      def initialize(path, issue_id, command)
        @path = path
        @command = command
        @mutex = Mutex.new
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        event(event: "start", action: command_action(command), status: "running", message: "Command started",
              details: { issue: issue_id, command: command })
      end

      def phase(message)
        event(event: "progress", action: "legacy.progress", status: "running", message: message)
      end

      def event(event:, action:, status:, message:, duration: nil, details: {})
        fields = {
          event: event,
          action: action,
          status: status,
          message: message
        }
        fields[:duration] = duration if duration
        safe_details = redact_details(details)
        fields[:details] = JSON.generate(safe_details) unless safe_details.empty?
        line = fields.map do |key, value|
          "#{key}=#{Shellwords.escape(redact(value.to_s))}"
        end.join(" ")
        write(line)
      end

      def command(argv, stdout:, stderr:, status:, duration:, env: {})
        safe_args = argv.each_with_index.map do |arg, index|
          redact(arg, index.zero? ? nil : argv[index - 1], env)
        end
        write("command #{safe_args.map { |arg| Shellwords.escape(arg) }.join(" ")}")
        write("stdout #{redact(stdout, nil, env)}") unless stdout.to_s.empty?
        write("stderr #{redact(stderr, nil, env)}") unless stderr.to_s.empty?
        write("duration=#{format("%.6f", duration)} status=#{status}")
        write("command_status=#{status}")
      end

      def finish(status = nil, action: nil, message: nil, details: {}, **keyword_values)
        status ||= keyword_values[:status]
        total_duration = @started_at ? Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at : nil
        event(event: "finish", action: action || "#{command_action(@command)}.finish",
              status: status || "success", message: message || "Command finished",
              duration: total_duration, details: details)
      end

      def append(path)
        File.foreach(path) { |line| write(redact(line.chomp)) }
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      private

      def command_action(command)
        command.to_s.downcase.gsub(/[^a-z0-9]+/, ".").gsub(/\A\.|\.\z/, "")
      end

      def write(message)
        @mutex.synchronize do
          File.open(@path, "a", 0o600) { |file| file.puts("[#{Time.now.utc.iso8601}] #{message}") }
        end
      end

      def redact(value, previous = nil, additional_secrets = {})
        return "[REDACTED]" if sensitive_name?(previous)

        text = value.to_s.dup
        ENV.to_h.merge(additional_secrets.to_h).each do |name, secret|
          next unless sensitive_name?(name) && secret && !secret.empty?

          text.gsub!(secret, "[REDACTED]")
        end
        text.gsub(INLINE_SECRET) { "#{$1}[REDACTED]" }
      end

      def redact_details(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), safe|
            safe[key] = sensitive_name?(key) ? "[REDACTED]" : redact_details(item)
          end
        when Array
          value.map { |item| redact_details(item) }
        else
          redact(value)
        end
      end

      def sensitive_name?(value)
        value.to_s.match?(SENSITIVE_NAME)
      end
    end

    module_function

    def start(issue_id, command, state_dir: nil)
      root = Pathname.new(state_dir || ENV["WORKSPACE_STATE_DIR"] || File.join(Dir.pwd, ".workspace")).expand_path
      directory = root.join("logs", issue_id.to_s)
      FileUtils.mkdir_p(directory)
      File.chmod(0o700, directory)
      timestamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
      path = directory.join("#{timestamp}-#{command.to_s.gsub(/[^A-Za-z0-9_.-]/, "-")}-#{SecureRandom.hex(4)}.log")
      File.open(path, File::CREAT | File::EXCL | File::WRONLY, 0o600).close
      Log.new(path.to_s, issue_id, command)
    rescue SystemCallError => error
      raise Error, "Could not initialize audit log: #{error.message}"
    end
  end
end
