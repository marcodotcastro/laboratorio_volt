# frozen_string_literal: true

require "json"

module Vdd
  module AI
    class Antigravity
      MAX_OUTPUT_BYTES = 20_000

      def self.call(prompt:, runner: Runner, env: ENV, logger: nil)
        message = JSON.generate(event: "user", message: { content: prompt }) + "\n"
        result = runner.run(["agy", "--input-format", "stream-json", "--output-format", "stream-json", "--sandbox"],
                            env: env, logger: logger, stdin_data: message)
        unless result.success?
          detail = result.stderr.to_s.strip
          detail = "executable not found" if result.status == 127 && detail.empty?
          detail = "exit #{result.status}" if detail.empty?
          code = result.status == 127 ? EXIT_DEPENDENCY : EXIT_EXTERNAL
          raise Error.new("Antigravity PR description failed: #{detail}", code: code)
        end

        body = result.stdout.to_s.lines.filter_map do |line|
          payload = JSON.parse(line)
          payload.dig("result", "response") if payload["event"] == "result"
        rescue JSON::ParserError
          nil
        end.last.to_s.byteslice(0, MAX_OUTPUT_BYTES).to_s.strip
        raise Error, "Antigravity returned an empty PR description" if body.empty?

        body
      end

      def self.repair(prompt:, root:, runner: Runner, env: ENV, logger: nil)
        result = runner.run(["agy", "-p", "--input-format", "text", "--output-format", "text", "--sandbox"],
                            chdir: root, env: env, logger: logger, stdin_data: prompt)
        raise_error(result, "Antigravity repair")
        result.stdout.to_s
      end

      def self.raise_error(result, name)
        return if result.success?

        detail = result.stderr.to_s.strip
        detail = "executable not found" if result.status == 127 && detail.empty?
        detail = "exit #{result.status}" if detail.empty?
        code = result.status == 127 ? EXIT_DEPENDENCY : EXIT_EXTERNAL
        raise Error.new("#{name} failed: #{detail}", code: code)
      end
      private_class_method :raise_error
    end
  end
end
