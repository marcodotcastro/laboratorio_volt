# frozen_string_literal: true

require "json"

module Vdd
  module Commands
    module DoctorFix
      module_function

      def call(context:, root:, deploy:, runner: Runner, env: ENV, logger: nil, state_dir: nil)
        before = Doctor.call(context: context, root: root, deploy: deploy,
                             runner: runner, env: env, logger: logger)
        base = result_for(before, checks_before: before[:checks], checks_after: before[:checks])
        return base.merge(fix_status: "not-needed", exit_code: EXIT_SUCCESS) if before[:errors].empty?

        provider = AI::ProviderConfig.load(env: env)
        return base.merge(
          fix_status: "blocked",
          errors: ["No AI provider configured; run vdd config ai-provider codex|claude|antigravity|gemini"],
          recommendations: (before[:recommendations] + ["configure an AI provider before using doctor --fix"]).uniq,
          exit_code: EXIT_CONTEXT
        ) unless provider

        snapshot_before = snapshot(context, root, runner: runner, env: env, logger: logger)
        repair = repair(provider, context: context, root: root, checks: before[:checks],
                        runner: runner, env: env, logger: logger, state_dir: state_dir)
        after = Doctor.call(context: context, root: root, deploy: deploy,
                            runner: runner, env: env, logger: logger)
        snapshot_after = snapshot(context, root, runner: runner, env: env, logger: logger)
        changed = changed_worktrees(snapshot_before, snapshot_after)
        errors = after[:errors].dup
        errors << repair[:error] if repair[:error]
        errors << "AI repair changed managed worktree files; review those changes before continuing" if changed.any?
        fix_status = if repair[:status] == "failed"
          "failed"
        elsif errors.empty?
          "resolved"
        else
          "unresolved"
        end
        result_for(after, checks_before: before[:checks], checks_after: after[:checks]).merge(
          fix_status: fix_status,
          provider: provider,
          repair: repair.merge(changed_worktrees: changed),
          errors: errors.uniq,
          recommendations: (after[:recommendations] + (changed.empty? ? [] : ["review managed worktree changes before retrying"])).uniq,
          exit_code: repair[:status] == "failed" ? repair.fetch(:exit_code, EXIT_EXTERNAL) : (errors.empty? ? EXIT_SUCCESS : EXIT_DEPENDENCY)
        )
      rescue Error => error
        result_for(before || { checks: [], warnings: [], errors: [], recommendations: [], status: "error" },
                   checks_before: before&.dig(:checks) || []).merge(
          fix_status: "failed",
          provider: provider,
          repair: { status: "failed", error: error.message },
          errors: [error.message],
          exit_code: error.code
        )
      end

      def result_for(payload, checks_before:, checks_after: nil)
        {
          status: payload[:status],
          phase: payload[:phase],
          checks: checks_after || payload[:checks],
          checks_before: checks_before,
          checks_after: checks_after || [],
          warnings: payload[:warnings],
          errors: payload[:errors],
          recommendations: payload[:recommendations],
          fix_requested: true
        }.compact
      end
      private_class_method :result_for

      def repair(provider, context:, root:, checks:, runner:, env:, logger:, state_dir:)
        output = AI::Provider.repair(
          provider,
          prompt: repair_prompt(root: root, context: context, checks: checks),
          root: root,
          runner: runner,
          env: env,
          logger: logger,
          state_dir: state_dir,
          issue_id: context&.issue_id
        )
        { status: "success", provider: provider, output: output.to_s.byteslice(0, 20_000).to_s.strip }
      rescue Error => error
        { status: "failed", provider: provider, error: error.message, exit_code: error.code }
      end
      private_class_method :repair

      def repair_prompt(root:, context:, checks:)
        failed = checks.reject { |check| check[:status] == "ok" }
        <<~PROMPT
          You are repairing the local development toolchain for VDD.

          Work only inside the workspace directory: #{root}
          Issue: #{context&.issue_id || "none"}

          Failed or warning checks:
          #{JSON.pretty_generate(failed)}

          Repair only local toolchains, package-manager installations, and local
          configuration needed to satisfy these checks. Do not edit product
          source code, package manifests, lockfiles, application data, or tests.
          Do not create branches or commits, push, open pull requests, delete
          Docker data, or access credentials. If the repair needs privilege,
          credentials, or a choice that is not explicit above, stop and explain
          what the operator must do manually. Finish with a short summary.
        PROMPT
      end
      private_class_method :repair_prompt

      def snapshot(context, root, runner:, env:, logger:)
        paths = {
          workspace: context&.workspace_path || root,
          backend: context&.backend_path,
          frontend: context&.frontend_path
        }
        paths.filter_map do |role, path|
          next unless path && File.directory?(path)

          result = runner.run(["git", "status", "--porcelain=v1", "--untracked-files=all"],
                              chdir: path, env: env, logger: logger)
          [role.to_s, { path: path, output: result.success? ? result.stdout : "error:#{result.status}" }]
        end.to_h
      end
      private_class_method :snapshot

      def changed_worktrees(before, after)
        after.filter_map do |role, current|
          next if before.dig(role, :output) == current[:output]

          { role: role, path: current[:path] }
        end
      end
      private_class_method :changed_worktrees
    end
  end
end
