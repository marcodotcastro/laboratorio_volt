# frozen_string_literal: true

require_relative "../errors"
require_relative "../deploy/github"
require_relative "../deploy/repository"

module Vdd
  module Commands
    module Deploy
      module_function

      ROLES = %i[backend frontend].freeze

      def call(context:, state_dir:, dry_run: false, provider: nil, runner: Runner, env: ENV, logger: nil,
               confirm: nil, select_provider: nil, persist_provider: nil)
        repositories = definitions(context, state_dir, env).each_with_object({}) do |(role, definition), result|
          result[role] = Vdd::Deploy::Repository.new(**definition).inspect(runner: runner, logger: logger)
        end

        errors = validation_errors(repositories)
        return failure(repositories, errors) unless errors.empty?

        publishable = repositories.values.select { |repository| repository[:commits_ahead].positive? }
        if publishable.empty?
          return { status: "no-changes", phase: "validated", repositories: repositories,
                   pull_requests: {}, provider: nil, errors: [], exit_code: EXIT_SUCCESS }
        end
        if dry_run
          repositories.each_value { |repository| repository[:plan] = "create" if repository[:commits_ahead].positive? }
          return { status: "dry-run", phase: "validated", repositories: repositories,
                   pull_requests: {}, provider: nil, planned_pull_requests: publishable.length,
                   errors: [], exit_code: EXIT_SUCCESS }
        end

        configured_provider = provider || AI::ProviderConfig.load(env: env, home: env.fetch("HOME"))
        selected_provider = configured_provider || select_provider&.call
        selected_provider = AI::Provider.normalize(selected_provider)

        unless confirm&.call(selected_provider, publishable.map { |repository| repository.fetch(:role) })
          return failure(repositories, ["Deploy cancelled; no push was performed"], code: EXIT_VALIDATION,
                         provider: selected_provider)
        end

        bodies = publishable.each_with_object({}) do |repository, result|
          result[repository.fetch(:role)] = AI::Provider.generate(
            selected_provider, prompt: prompt(repository), runner: runner, env: env, logger: logger,
            state_dir: state_dir, issue_id: context.issue_id
          )
        end
        persist_provider&.call(selected_provider) if provider.nil? && configured_provider.nil?

        github = Vdd::Deploy::GitHub.new(state_dir: state_dir, issue_id: context.issue_id,
                                         runner: runner, env: env, logger: logger)
        pull_requests = {}
        sibling_url = nil
        publishable.each do |repository|
          begin
            existing_url = github.existing_pull_request(repository)
            if existing_url
              repository[:pr_url] = existing_url
              pull_requests[repository[:role]] = existing_url
              sibling_url ||= existing_url
              next
            end
            github.push(repository)
            url = github.create_pull_request(repository, body: bodies.fetch(repository.fetch(:role)), sibling_url: sibling_url)
            repository[:pr_url] = url
            pull_requests[repository[:role]] = url
            sibling_url ||= url
          rescue Error => error
            return {
              status: "error", phase: "publishing", repositories: result_repositories(repositories),
              provider: selected_provider,
              pull_requests: pull_requests, errors: ["#{repository[:role]} deploy failed: #{error.message}; retry deploy to complete remaining PRs"],
              exit_code: EXIT_EXTERNAL
            }
          end
        end

        { status: "success", phase: "complete", repositories: result_repositories(repositories),
          provider: selected_provider, pull_requests: pull_requests, errors: [], exit_code: EXIT_SUCCESS }
      rescue Error => error
        { status: "error", phase: "provider", repositories: result_repositories(repositories || {}),
          provider: selected_provider, pull_requests: {}, errors: [error.message], exit_code: error.code }
      end

      def render(payload)
        lines = ["provider: #{payload[:provider] || "-"}", "repository  status   ahead  plan     pull request"]
        lines << "----------  -------  -----  -------  ------------"
        payload.fetch(:repositories).each do |role, repository|
          lines << format("%-10s  %-7s  %5s  %-7s  %s", role, repository[:status],
                          repository[:commits_ahead], repository[:plan] || "-", repository[:pr_url] || "-")
          lines << "  dirty files: #{repository[:dirty_files].join(", ")}" if repository[:dirty]
        end
        lines << "pull requests: #{payload.fetch(:pull_requests, {}).length}"
        lines.join("\n")
      end

      def definitions(context, state_dir, env)
        {
          backend: {
            role: :backend, path: context.backend_path, expected_branch: context.issue_branch,
            base: env.fetch("CRM_BASE_REF", "main"), github_repository: env["CRM_GITHUB_REPO"],
            state_dir: state_dir, issue_id: context.issue_id
          },
          frontend: {
            role: :frontend, path: context.frontend_path, expected_branch: context.issue_branch,
            base: env.fetch("AIO_BASE_REF", "main"), github_repository: env["AIO_GITHUB_REPO"],
            state_dir: state_dir, issue_id: context.issue_id
          }
        }
      end
      private_class_method :definitions

      def validation_errors(repositories)
        repositories.values.flat_map do |repository|
          errors = []
          if repository[:error]
            errors << "#{repository[:role]}: #{repository[:error]}"
          else
            if repository[:dirty]
              paths = repository[:dirty_files].map { |file| File.join(repository[:path], file) }
              errors << "#{repository[:role]} worktree has uncommitted changes: #{paths.join(", ")}; commit manually and run deploy again"
            end
            errors << "#{repository[:role]} branch #{repository[:branch].inspect} does not match expected #{repository[:expected_branch]}" unless repository[:branch_matches]
          end
          errors
        end
      end
      private_class_method :validation_errors

      def prompt(repository)
        tests = repository[:last_test] || {}
        <<~PROMPT
          Write the markdown body for a pull request in a software project.
          Return only the body, without a title, preamble, or code fence.
          Base the description strictly on the implementation evidence below;
          the issue description is not available and must not be invented.

          Repository role: #{repository.fetch(:role)}
          Branch: #{repository.fetch(:branch)}
          Base branch: #{repository.fetch(:base)}
          Commits:
          #{repository.fetch(:commit_subjects).join("\n")}

          Changed files:
          #{repository.fetch(:changed_files).join("\n")}

          Diff stat:
          #{repository.fetch(:diff_stat)}

          Test summary: #{tests.fetch("status", "not run")}
          Test log: #{tests.fetch("log_file", "not available")}

          Patch:
          #{repository.fetch(:diff)}

          Summarize what changed, why the implementation is shaped this way,
          and how it was validated. Keep the result concise and specific to
          this repository.
        PROMPT
      end
      private_class_method :prompt

      def result_repositories(repositories)
        repositories.transform_values { |repository| repository.reject { |key, _value| key == :diff } }
      end
      private_class_method :result_repositories

      def failure(repositories, errors, code: EXIT_VALIDATION, provider: nil)
        { status: "error", phase: "validated", repositories: result_repositories(repositories),
          provider: provider, pull_requests: {}, errors: errors, exit_code: code }
      end
      private_class_method :failure
    end
  end
end
