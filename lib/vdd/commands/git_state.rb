# frozen_string_literal: true

module Vdd
  module Commands
    module GitState
      module_function

      def collect(role, path, expected_branch:, base:, runner: Runner, logger: nil)
        record = {
          role: role,
          path: path,
          branch: nil,
          expected_branch: expected_branch,
          branch_matches: false,
          base: base,
          sha: nil,
          dirty: false,
          dirty_files: [],
          status_porcelain: "",
          commits_ahead: 0,
          exists: false,
          error: nil
        }
        return record.merge(error: "worktree path is not configured") if path.to_s.empty?
        return record.merge(error: "worktree does not exist") unless File.directory?(path)

        record[:exists] = true
        branch = run(runner, %w[git branch --show-current], path, logger)
        return record.merge(error: command_error("branch", branch)) unless branch.success?

        status = run(runner, ["git", "status", "--porcelain=v1", "--untracked-files=all"], path, logger)
        return record.merge(error: command_error("status", status)) unless status.success?

        sha = run(runner, %w[git rev-parse HEAD], path, logger)
        return record.merge(error: command_error("sha", sha)) unless sha.success?

        ahead = run(runner, ["git", "rev-list", "--count", "#{base}..HEAD"], path, logger)
        return record.merge(error: command_error("commits ahead", ahead)) unless ahead.success?

        porcelain = status.stdout
        current_branch = branch.stdout.strip
        record.merge(
          branch: current_branch,
          branch_matches: current_branch == expected_branch,
          sha: sha.stdout.strip,
          dirty: !porcelain.empty?,
          dirty_files: porcelain.lines.map { |line| line[3..].to_s.strip }.reject(&:empty?),
          status_porcelain: porcelain,
          commits_ahead: Integer(ahead.stdout.strip, 10)
        )
      rescue ArgumentError
        record.merge(error: "git returned an invalid commits-ahead count")
      end

      def run(runner, argv, path, logger)
        runner.run(argv, chdir: path, logger: logger)
      end
      private_class_method :run

      def command_error(name, result)
        message = result.stderr.to_s.strip
        message = "exit #{result.status}" if message.empty?
        "git #{name} failed: #{message}"
      end
      private_class_method :command_error
    end
  end
end
