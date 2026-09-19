# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../errors"
require_relative "../runner"

module Vdd
  module Deploy
    class GitHub
      class << self
        def repository_name(remote)
          value = remote.to_s.strip
          match = value.match(%r{github\.com[:/]([^/]+/[^/]+?)(?:\.git)?\z}i)
          match && match[1]
        end
      end

      def initialize(state_dir:, issue_id:, runner: Runner, env: ENV, logger: nil)
        @state_dir = state_dir.to_s
        @issue_id = issue_id.to_s
        @runner = runner
        @env = env
        @logger = logger
      end

      def push(repository)
        result = @runner.run(["git", "push", "--set-upstream", "origin", repository.fetch(:branch)],
                             chdir: repository.fetch(:path), env: @env, logger: @logger)
        return result if result.success?

        raise Error, external_error("push #{repository.fetch(:role)}", result)
      end

      def existing_pull_request(repository)
        return nil if repository.fetch(:github_repository).to_s.empty?

        result = @runner.run(
          ["gh", "pr", "list", "--repo", repository.fetch(:github_repository).to_s,
           "--head", repository.fetch(:branch), "--base", repository.fetch(:base),
           "--state", "open", "--json", "url", "--limit", "1"],
          chdir: repository.fetch(:path), env: @env, logger: @logger
        )
        return nil unless result.success?

        Array(JSON.parse(result.stdout.to_s)).first&.fetch("url", nil)
      rescue JSON::ParserError => error
        raise Error, "GitHub returned invalid pull request data: #{error.message}"
      end

      def create_pull_request(repository, body:, sibling_url: nil)
        repo_name = repository.fetch(:github_repository).to_s
        raise Error, "GitHub repository is unavailable for #{repository.fetch(:role)}" if repo_name.empty?

        body_path = write_body(repository, body, sibling_url)
        argv = ["gh", "pr", "create", "--repo", repo_name, "--head", repository.fetch(:branch),
                "--base", repository.fetch(:base), "--title", title(repository), "--body-file", body_path]
        result = @runner.run(argv, chdir: repository.fetch(:path), env: @env, logger: @logger)
        return result.stdout.to_s.lines.last.to_s.strip if result.success? && !result.stdout.to_s.lines.last.to_s.strip.empty?

        raise Error, external_error("create #{repository.fetch(:role)} pull request", result)
      ensure
        FileUtils.rm_f(body_path) if body_path
      end

      private

      def write_body(repository, body, sibling_url)
        directory = File.join(@state_dir, "runtime", @issue_id)
        FileUtils.mkdir_p(directory)
        path = File.join(directory, "deploy-#{repository.fetch(:role)}-pr.md")
        content = body.to_s.strip
        content = "#{content}\n\nRelated PR: #{sibling_url}" if sibling_url
        File.write(path, "#{content}\n", mode: "w", perm: 0o600)
        path
      end

      def title(repository)
        "#{@issue_id} #{repository.fetch(:role)} changes"
      end

      def external_error(action, result)
        detail = result.stderr.to_s.strip
        detail = result.stdout.to_s.strip if detail.empty?
        detail = "exit #{result.status}" if detail.empty?
        "GitHub #{action} failed: #{detail}"
      end
    end

    Github = GitHub unless const_defined?(:Github)
  end
end
