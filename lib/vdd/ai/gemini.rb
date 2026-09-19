# frozen_string_literal: true

module Vdd
  module AI
    class Gemini
      MAX_OUTPUT_BYTES = 20_000

      def self.call(prompt:, runner: Runner, env: ENV, logger: nil)
        result = runner.run(["gemini", "--prompt", "", "--approval-mode", "plan", "--output-format", "text"],
                            env: env, logger: logger, stdin_data: prompt)
        unless result.success?
          detail = result.stderr.to_s.strip
          detail = "executable not found" if result.status == 127 && detail.empty?
          detail = "exit #{result.status}" if detail.empty?
          code = result.status == 127 ? EXIT_DEPENDENCY : EXIT_EXTERNAL
          raise Error.new("Gemini PR description failed: #{detail}", code: code)
        end

        body = result.stdout.to_s.byteslice(0, MAX_OUTPUT_BYTES).to_s.strip
        raise Error, "Gemini returned an empty PR description" if body.empty?

        body
      end

      def self.repair(prompt:, root:, runner: Runner, env: ENV, logger: nil)
        result = runner.run(["gemini", "--prompt", "", "--approval-mode", "auto_edit", "--output-format", "text", "--sandbox"],
                            chdir: root, env: env, logger: logger, stdin_data: prompt)
        raise_error(result, "Gemini repair")
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
