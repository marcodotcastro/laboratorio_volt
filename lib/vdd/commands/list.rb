# frozen_string_literal: true

module Vdd
  module Commands
    module List
      module_function

      def call(state_dir:, runner: Runner, env: ENV, logger: nil)
        paths = Dir.glob(File.join(state_dir.to_s, "issues", "CC-*.env")).sort
        workspaces = paths.map { |path| workspace_record(path, runner: runner, env: env, logger: logger) }
        return { status: "no-workspaces", phase: "complete", message: "No issue workspaces available", workspaces: [] } if workspaces.empty?

        { status: "success", phase: "complete", workspaces: workspaces }
      end

      def render(payload)
        return payload.fetch(:message) if payload[:message]

        lines = ["issue    type         branch                   status       path",
                 "-------  -----------  -----------------------  -----------  ----"]
        payload.fetch(:workspaces).each do |workspace|
          status = workspace[:status] == "invalid" ? "unavailable" : workspace.fetch(:status)
          lines << format("%-7s  %-11s  %-23s  %-11s  %s", workspace.fetch(:issue), workspace.fetch(:type, "-"),
                          workspace.fetch(:branch, "-"), status, workspace.fetch(:path, "-"))
        end
        lines.join("\n")
      end

      def workspace_record(path, runner:, env:, logger:)
        issue = File.basename(path, ".env").upcase
        values = Manifest.load(path)
        repositories = repository_definitions(values, env).each_with_object({}) do |(role, definition), result|
          result[role] = GitState.collect(role, definition.fetch(:path), **definition.except(:path), runner: runner, logger: logger)
        end

        {
          issue: issue,
          number: values.fetch("ISSUE_NUMBER").to_i,
          type: values.fetch("ISSUE_TYPE"),
          branch: values.fetch("ISSUE_BRANCH"),
          status: aggregate_status(repositories),
          path: values.fetch("WORKSPACE_WORKTREE_PATH"),
          repositories: repositories
        }
      rescue ContextError => error
        { issue: issue, status: "invalid", manifest_path: path, error: error.message }
      end

      def repository_definitions(values, env)
        {
          workspace: { path: values["WORKSPACE_WORKTREE_PATH"], expected_branch: values["ISSUE_BRANCH"],
                       base: env.fetch("WORKSPACE_BASE_REF", "main") },
          backend: { path: values["CRM_WORKTREE_PATH"], expected_branch: values["ISSUE_BRANCH"],
                    base: env.fetch("CRM_BASE_REF", "main") },
          frontend: { path: values["AIO_WORKTREE_PATH"], expected_branch: values["ISSUE_BRANCH"],
                     base: env.fetch("AIO_BASE_REF", "main") }
        }
      end

      def aggregate_status(repositories)
        states = repositories.values
        return "incomplete" if states.any? { |repository| repository[:error] }
        return "pending" if states.any? { |repository| repository[:dirty] }
        return "committed" if states.any? { |repository| repository[:commits_ahead].positive? }

        "created"
      end

      private_class_method :workspace_record, :repository_definitions, :aggregate_status
    end
  end
end
