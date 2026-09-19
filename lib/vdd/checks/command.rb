# frozen_string_literal: true

module Vdd
  module Checks
    module Command
      module_function

      def call(name, args: ["--version"], required: true, recommendation: nil, minimum_version: nil,
              runner: Runner, env: ENV, logger: nil)
        result = runner.run([name, *args], env: env, logger: logger)
        if result.success?
          check = success(name, result)
          if minimum_version && (!version_from(result) || compare_versions(version_from(result), minimum_version) < 0)
            actual = version_from(result)
            return check.merge(status: "error", message: "#{name} #{actual.empty? ? "unknown version" : actual} is older than #{minimum_version.join(".")}",
                               recommendation: recommendation)
          end

          return check
        end

        status = required ? "error" : "warning"
        message = result.stderr.to_s.strip
        message = "exit #{result.status}" if message.empty?
        record(name, status, "#{name} unavailable: #{message}", recommendation)
      rescue StandardError => error
        record(name, required ? "error" : "warning", "#{name} unavailable: #{error.message}", recommendation)
      end

      def success(name, result)
        record(name, "ok", "#{name} available", nil, version: version_from(result))
      end
      private_class_method :success

      def record(name, status, message, recommendation, version: nil)
        { name: name, status: status, message: message, recommendation: recommendation, version: version }.compact
      end
      private_class_method :record

      def version_from(result)
        result.stdout.to_s.strip.lines.first.to_s.strip
      end
      private_class_method :version_from

      def compare_versions(actual, expected)
        actual_version = actual.to_s.scan(/\d+/).first(3).map(&:to_i)
        actual_version.fill(0, actual_version.length...3)
        actual_version <=> expected
      end
      private_class_method :compare_versions
    end
  end
end
