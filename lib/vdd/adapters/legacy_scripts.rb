# frozen_string_literal: true

module Vdd
  module Adapters
    module LegacyScripts
      ROOT = File.expand_path("../../../", __dir__)
      SCRIPTS = {
        issue_create: ["scripts/issue.sh"],
        issue_destroy: ["scripts/issue-destroy.sh"],
        runtime: ["scripts/runtime.sh"]
      }.freeze

      module_function

      def issue_create(issue, type: "improvement", state_dir: nil, runner: Runner, logger: nil, on_event: nil)
        execute(SCRIPTS.fetch(:issue_create), issue: issue, type: type, state_dir: state_dir, runner: runner,
                logger: logger, on_event: on_event)
      end

      def issue_destroy(issue, state_dir: nil, runner: Runner, logger: nil, confirmation: nil, on_event: nil)
        execute(SCRIPTS.fetch(:issue_destroy), issue: issue, state_dir: state_dir, runner: runner,
                logger: logger, stdin_data: confirmation, on_event: on_event)
      end

      def runtime(action, issue:, state_dir: nil, runner: Runner, logger: nil, on_event: nil)
        unless %w[up down restart reset].include?(action.to_s)
          raise UsageError, "Unknown runtime action #{action.inspect}"
        end

        execute(SCRIPTS.fetch(:runtime) + [action.to_s], issue: issue, state_dir: state_dir, runner: runner,
                logger: logger, on_event: on_event)
      end

      def execute(script_parts, issue:, type: nil, state_dir:, runner:, logger:, stdin_data: nil, on_event: nil)
        issue_id = Context.normalize_issue(issue)
        log_directory = state_dir && File.join(state_dir.to_s, "logs", issue_id)
        known_logs = log_directory ? Dir.glob(File.join(log_directory, "*.log")) : []
        environment = {
          "WORKSPACE_ISSUE_ID" => issue_id,
          "ISSUE" => issue_id
        }
        environment["TYPE"] = Context.normalize_type(type) if type
        environment["WORKSPACE_STATE_DIR"] = state_dir.to_s if state_dir
        if logger
          environment["WORKSPACE_LOG_FILE"] = logger.path
          environment["WORKSPACE_LOG_FILE_EXTERNAL"] = "true"
        end
        environment["WORKSPACE_EVENT_STREAM"] = "true" if on_event
        command = [File.join(ROOT, script_parts.first), *script_parts.drop(1)]
        result = runner.run(command, chdir: ROOT, env: environment, logger: logger, stdin_data: stdin_data,
                            on_event: on_event)
        import_new_logs(log_directory, known_logs, logger)
        result
      end

      def import_new_logs(directory, known_logs, logger)
        return unless directory && logger

        Dir.glob(File.join(directory, "*.log")).sort.each do |path|
          logger.append(path) unless known_logs.include?(path) || path == logger.path
        end
      end
      private_class_method :import_new_logs
      private_class_method :execute
    end
  end
end
