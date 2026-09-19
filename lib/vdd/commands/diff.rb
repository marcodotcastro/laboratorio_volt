# frozen_string_literal: true

module Vdd
  module Commands
    module Diff
      module_function

      def call(context:, full: false, runner: Runner, env: ENV, logger: nil)
        repositories = Status.repository_definitions(context, env).each_with_object({}) do |(role, definition), result|
          state = GitState.collect(role, definition.fetch(:path), **definition.except(:path), runner: runner, logger: logger)
          result[role] = state.merge(
            files: changed_files(state, runner, logger),
            stat: diff_stat(state, runner, logger),
            deployable: state[:error].nil? && !state[:dirty] && state[:commits_ahead].positive?
          )
          result[role][:patch] = full_patch(state, runner, logger) if full && state[:error].nil?
        end
        { status: "success", phase: "complete", repositories: repositories }
      end

      def render(payload)
        lines = ["repository  branch                   ahead  files  deployable  path",
                 "----------  -----------------------  -----  -----  ----------  ----"]
        payload.fetch(:repositories).each do |role, repository|
          lines << format("%-10s  %-23s  %5s  %5s  %-10s  %s", role,
                          repository[:branch] || "unknown", repository[:commits_ahead] || "-",
                          repository.fetch(:files, []).length, repository[:deployable], repository[:path])
          lines << "  files: #{repository[:files].join(", ")}" unless repository.fetch(:files, []).empty?
          lines << "  stat: #{repository[:stat]}" unless repository[:stat].to_s.empty?
          lines << repository[:patch] if repository.key?(:patch) && !repository[:patch].empty?
        end
        lines.join("\n")
      end

      def changed_files(state, runner, logger)
        return [] if state[:error]

        committed = run(runner, ["git", "diff", "--name-only", "#{state[:base]}...HEAD"], state[:path], logger)
        working = run(runner, ["git", "diff", "--name-only"], state[:path], logger)
        (committed.stdout.to_s.lines + working.stdout.to_s.lines + state[:dirty_files]).map(&:strip).reject(&:empty?).uniq.sort
      end
      private_class_method :changed_files

      def diff_stat(state, runner, logger)
        return "" if state[:error]

        committed = run(runner, ["git", "diff", "--shortstat", "#{state[:base]}...HEAD"], state[:path], logger)
        working = run(runner, ["git", "diff", "--shortstat"], state[:path], logger)
        [committed.stdout, working.stdout].map { |value| value.to_s.strip }.reject(&:empty?).join("; ")
      end
      private_class_method :diff_stat

      def full_patch(state, runner, logger)
        committed = run(runner, ["git", "diff", "#{state[:base]}...HEAD"], state[:path], logger)
        working = run(runner, ["git", "diff"], state[:path], logger)
        [committed.stdout, working.stdout].join
      end
      private_class_method :full_patch

      def run(runner, argv, path, logger)
        runner.run(argv, chdir: path, logger: logger)
      end
      private_class_method :run
    end
  end
end
