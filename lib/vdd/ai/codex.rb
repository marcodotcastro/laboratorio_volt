# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"

module Vdd
  module AI
    class Codex
      MAX_OUTPUT_BYTES = 20_000

      def self.call(prompt:, runner: Runner, env: ENV, logger: nil, state_dir: nil, issue_id: nil)
        new(prompt: prompt, runner: runner, env: env, logger: logger,
            state_dir: state_dir, issue_id: issue_id).call
      end

      def self.repair(prompt:, root:, runner: Runner, env: ENV, logger: nil, state_dir: nil, issue_id: nil)
        worker = new(prompt: prompt, runner: runner, env: env, logger: logger,
                     state_dir: state_dir || Dir.tmpdir, issue_id: issue_id || "doctor")
        output_path = worker.send(:temporary_output_path)
        result = runner.run(["codex", "exec", "--sandbox", "workspace-write", "--output-last-message", output_path],
                            chdir: root, env: env, logger: logger, stdin_data: prompt)
        worker.send(:raise_error, result, "Codex repair") unless result.success?
        File.file?(output_path) ? File.read(output_path, mode: "rb") : result.stdout.to_s
      ensure
        FileUtils.rm_f(output_path) if output_path
      end

      def initialize(prompt:, runner:, env:, logger:, state_dir:, issue_id:)
        @prompt = prompt
        @runner = runner
        @env = env
        @logger = logger
        @state_dir = state_dir
        @issue_id = issue_id
      end

      def call
        output_path = temporary_output_path
        result = @runner.run(["codex", "exec", "--sandbox", "read-only", "--output-last-message", output_path],
                             env: @env, logger: @logger, stdin_data: @prompt)
        raise_error(result, "Codex") unless result.success?

        body = File.read(output_path, mode: "rb")
        raise Error, "Codex returned an empty PR description" if body.strip.empty?

        body.byteslice(0, MAX_OUTPUT_BYTES).strip
      ensure
        FileUtils.rm_f(output_path) if output_path
      end

      private

      def temporary_output_path
        directory = File.join(@state_dir.to_s, "runtime", @issue_id.to_s)
        FileUtils.mkdir_p(directory, mode: 0o700)
        path = File.join(directory, "codex-#{SecureRandom.hex(6)}.md")
        File.open(path, File::CREAT | File::WRONLY, 0o600).close
        path
      end

      def raise_error(result, name)
        detail = result.stderr.to_s.strip
        detail = "executable not found" if result.status == 127 && detail.empty?
        detail = "exit #{result.status}" if detail.empty?
        code = result.status == 127 ? EXIT_DEPENDENCY : EXIT_EXTERNAL
        raise Error.new("#{name} PR description failed: #{detail}", code: code)
      end
    end
  end
end
