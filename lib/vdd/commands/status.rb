# frozen_string_literal: true

require "json"

module Vdd
  module Commands
    module Status
      module_function

      def call(context:, runner: Runner, env: ENV, logger: nil)
        repositories = repository_definitions(context, env).each_with_object({}) do |(role, definition), result|
          result[role] = GitState.collect(role, definition.fetch(:path), **definition.except(:path), runner: runner, logger: logger)
        end
        warnings = []
        containers = container_state(runner, logger: logger)
        warnings << containers.delete(:warning) if containers[:warning]
        runtime = runtime_state(context, containers, runner: runner, logger: logger)
        { status: "ok", phase: "complete", repositories: repositories, containers: containers,
          runtime_urls: runtime.fetch(:urls), runtime_endpoints: runtime.fetch(:endpoints), warnings: warnings }
      end

      def empty(issue: nil)
        message = issue ? "No issue workspace available for #{issue}" : "No issue workspace available"
        { status: "no-workspace", phase: "complete", issue: issue, message: message, repositories: {},
          containers: {}, runtime_urls: {}, runtime_endpoints: {}, warnings: [] }
      end

      def render(payload)
        return payload.fetch(:message) if payload[:message]

        rows = payload.fetch(:repositories).map do |role, repository|
          next [role, "missing", "-", "-", "-", "-", repository.fetch(:path, "-")] if repository[:error]

          [role, repository[:branch] || "detached", repository[:expected_branch] || "-",
           repository[:dirty] ? "dirty" : "clean", repository[:commits_ahead], repository[:sha].to_s[0, 8], repository[:path]]
        end
        lines = [
          "repository  branch                   expected                  state  ahead  sha       path",
          "----------  -----------------------  -------------------------  -----  -----  --------  ----"
        ]
        lines.concat(rows.map { |row| format("%-10s  %-23s  %-25s  %-5s  %5s  %-8s  %s", *row) })
        lines << ""
        lines << "runtime endpoints"
        payload.fetch(:runtime_endpoints, {}).each do |role, endpoint|
          lines << format("%-18s  %s", role, endpoint.fetch(:status, "not-running"))
        end
        payload.fetch(:warnings, []).each { |warning| lines << "warning: #{warning}" }
        lines.join("\n")
      end

      def repository_definitions(context, env)
        {
          backend: { path: context.backend_path, expected_branch: context.issue_branch,
                     base: env.fetch("CRM_BASE_REF", "main") },
          frontend: { path: context.frontend_path, expected_branch: context.issue_branch,
                      base: env.fetch("AIO_BASE_REF", "main") },
          workspace: { path: context.workspace_path, expected_branch: context.issue_branch,
                       base: env.fetch("WORKSPACE_BASE_REF", "main") }
        }
      end
      def container_state(runner, logger: nil)
        version = runner.run(%w[docker --version], logger: logger)
        return { status: "warning", warning: "Docker unavailable; container state omitted" } unless version.success?

        result = runner.run(["docker", "ps", "--format", "{{.Names}}\t{{.Status}}"], logger: logger)
        return { status: "warning", warning: "Docker container state unavailable" } unless result.success?

        { status: "ok", containers: result.stdout.lines.filter_map do |line|
          name, state = line.chomp.split("\t", 2)
          { name: name, status: state }
        end }
      end

      def runtime_state(context, containers, runner:, logger: nil)
        urls = runtime_urls(context)
        endpoints = urls.keys.to_h { |role| [role, { status: "not-running" }] }
        return { urls: urls, endpoints: endpoints } unless runtime_running?(context, containers)

        endpoints = urls.transform_values do |url|
          { status: endpoint_status(url, runner: runner, logger: logger) }
        end
        { urls: urls, endpoints: endpoints }
      end

      def runtime_urls(context)
        workspace = "http://cc#{context.issue_number}.localhost"
        {
          workspace: workspace,
          all_in_one: "#{workspace}:3000",
          imob: "#{workspace}:3001",
          backend: "#{workspace}:3002",
          styleguide: "#{workspace}:3003"
        }
      end

      def runtime_running?(context, containers)
        return false unless containers[:status] == "ok"

        prefix = "c2s-workspace-#{context.issue_id.downcase}-"
        containers.fetch(:containers, []).any? do |container|
          container.fetch(:name, "").start_with?(prefix) &&
            container.fetch(:name, "").include?("crm-web") &&
            container.fetch(:status, "").match?(/\bup\b/i)
        end
      end

      def endpoint_status(url, runner:, logger: nil, attempts: 2)
        attempts.times do |attempt|
          result = runner.run(["curl", "--silent", "--show-error", "--output", "/dev/null",
                               "--max-time", "3", "--write-out", "%{http_code}", url], logger: logger)
          if result.success?
            code = result.stdout.to_s.strip
            return "redirect" if code.match?(/\A3\d\d\z/)
            return "ok" if code.match?(/\A2\d\d\z/)
          end
          sleep(0.5) if attempt < attempts - 1
        end
        "unreachable"
      end

      private_class_method :container_state, :runtime_state, :runtime_urls, :runtime_running?, :endpoint_status
    end
  end
end
