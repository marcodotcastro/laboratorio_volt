# frozen_string_literal: true

require "json"
require_relative "../runner"
require_relative "github"

module Vdd
  module Deploy
    class Repository
      attr_reader :role, :path, :expected_branch, :base, :github_repository

      def initialize(role:, path:, expected_branch:, base:, github_repository: nil, state_dir: nil, issue_id: nil)
        @role = role.to_sym
        @path = path.to_s
        @expected_branch = expected_branch.to_s
        @base = base.to_s
        @github_repository = github_repository
        @state_dir = state_dir
        @issue_id = issue_id
      end

      def self.call(runner: Runner, logger: nil, **attributes)
        new(**attributes).inspect(runner: runner, logger: logger)
      end

      def inspect(runner: Runner, logger: nil)
        record = {
          role: role,
          path: path,
          expected_branch: expected_branch,
          base: base,
          branch: nil,
          branch_matches: false,
          dirty: false,
          dirty_files: [],
          status_porcelain: "",
          commits_ahead: 0,
          commit_subjects: [],
          changed_files: [],
          diff_stat: "",
          diff: "",
          remote: nil,
          github_repository: github_repository,
          last_test: last_test,
          status: "blocked",
          error: nil
        }
        return record.merge(error: "#{role} worktree is not configured") if path.empty?
        return record.merge(error: "#{role} worktree does not exist: #{path}") unless File.directory?(path)

        branch = run(runner, %w[git branch --show-current], logger)
        return record.merge(error: command_error("branch", branch)) unless branch.success?

        status = run(runner, ["git", "status", "--porcelain=v1", "--untracked-files=all"], logger)
        return record.merge(error: command_error("status", status)) unless status.success?

        current_branch = branch.stdout.to_s.strip
        dirty_files = status.stdout.to_s.lines.map { |line| line[3..].to_s.strip }.reject(&:empty?)
        return record.merge(branch: current_branch, branch_matches: current_branch == expected_branch,
                            dirty: true, dirty_files: dirty_files, status_porcelain: status.stdout.to_s,
                            error: nil) unless status.stdout.to_s.empty?

        base_ref = run(runner, ["git", "rev-parse", "--verify", base], logger)
        return record.merge(error: "#{role} base ref is unavailable: #{base}") unless base_ref.success?

        ahead = run(runner, ["git", "rev-list", "--count", "#{base}..HEAD"], logger)
        return record.merge(error: command_error("commits ahead", ahead)) unless ahead.success?

        remote = run(runner, %w[git remote get-url origin], logger)
        return record.merge(error: command_error("remote", remote)) unless remote.success?

        commits_ahead = Integer(ahead.stdout.to_s.strip, 10)
        commit_subjects = run(runner, ["git", "log", "--format=%h %s", "#{base}..HEAD"], logger)
        return record.merge(error: command_error("commit subjects", commit_subjects)) unless commit_subjects.success?

        changed_files = run(runner, ["git", "diff", "--name-only", "#{base}...HEAD"], logger)
        return record.merge(error: command_error("changed files", changed_files)) unless changed_files.success?

        diff_stat = run(runner, ["git", "diff", "--stat", "#{base}...HEAD"], logger)
        return record.merge(error: command_error("diff stat", diff_stat)) unless diff_stat.success?

        diff = run(runner, ["git", "diff", "--no-ext-diff", "--unified=80", "#{base}...HEAD"], logger)
        return record.merge(error: command_error("diff", diff)) unless diff.success?

        record.merge(
          branch: current_branch,
          branch_matches: current_branch == expected_branch,
          dirty: !status.stdout.to_s.empty?,
          dirty_files: dirty_files,
          status_porcelain: status.stdout.to_s,
          commits_ahead: commits_ahead,
          commit_subjects: commit_subjects.stdout.to_s.lines.map(&:strip).reject(&:empty?),
          changed_files: changed_files.stdout.to_s.lines.map(&:strip).reject(&:empty?),
          diff_stat: diff_stat.stdout.to_s.strip,
          diff: diff.stdout.to_s,
          remote: remote.stdout.to_s.strip,
          github_repository: github_repository || GitHub.repository_name(remote.stdout.to_s.strip),
          status: commits_ahead.positive? ? "ready" : "skipped"
        )
      rescue ArgumentError
        record.merge(error: "git returned an invalid commits-ahead count")
      end

      private

      def last_test
        return nil unless @state_dir && @issue_id

        path = File.join(@state_dir.to_s, "runtime", @issue_id.to_s, "tests.json")
        return nil unless File.file?(path)

        payload = JSON.parse(File.read(path))
        component = payload.fetch("tests", []).find { |test| test["component"] == role.to_s }
        component && component.slice("status", "exit_status", "finished_at", "log_file")
      rescue JSON::ParserError, KeyError
        { "status" => "invalid" }
      end

      def run(runner, argv, logger)
        runner.run(argv, chdir: path, logger: logger)
      end

      def command_error(name, result)
        detail = result.stderr.to_s.strip
        detail = "exit #{result.status}" if detail.empty?
        "git #{name} failed: #{detail}"
      end
    end
  end
end
