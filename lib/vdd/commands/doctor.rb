# frozen_string_literal: true

module Vdd
  module Commands
    module Doctor
      module_function

      def call(context:, root: Dir.pwd, deploy: false, runner: Runner, env: ENV, logger: nil)
        checks = command_checks(deploy, runner: runner, env: env, logger: logger)
        checks.concat(Checks::Workspace.call(context: context, root: root))
        frontend = context&.frontend_path || root
        checks.concat(Checks::Javascript.call(path: frontend, runner: runner, env: env, logger: logger))
        warnings = checks.filter_map { |check| check[:message] if check[:status] == "warning" }
        errors = checks.filter_map { |check| check[:message] if check[:status] == "error" }
        recommendations = checks.filter_map { |check| check[:recommendation] }.uniq
        {
          status: errors.empty? ? (warnings.empty? ? "ok" : "warning") : "error",
          phase: "complete",
          checks: checks,
          warnings: warnings,
          errors: errors,
          recommendations: recommendations
        }
      end

      def render(payload)
        lines = ["check                 status   message"]
        lines << "--------------------  -------  ----------------------------------------"
        payload.fetch(:checks).each do |check|
          lines << format("%-21s  %-7s  %s", check[:name], check[:status], check[:message])
          lines << "  recommendation: #{check[:recommendation]}" if check[:recommendation]
        end
        if payload[:fix_requested]
          lines << "doctor fix: #{payload[:fix_status]}"
          lines << "provider: #{payload[:provider]}" if payload[:provider]
        end
        lines << "doctor status: #{payload[:status]}"
        lines.join("\n")
      end

      def command_checks(deploy, runner:, env:, logger:)
        checks = [
          Checks::Command.call("ruby", minimum_version: [3, 3, 0], recommendation: "install Ruby 3.3 or newer", runner: runner, env: env, logger: logger),
          Checks::Command.call("bundle", recommendation: "install Bundler with gem install bundler", runner: runner, env: env, logger: logger),
          thor_check,
          Checks::Command.call("git", recommendation: "install Git", runner: runner, env: env, logger: logger),
          Checks::Command.call("docker", required: false, recommendation: "install Docker", runner: runner, env: env, logger: logger),
          compose_check(runner: runner, env: env, logger: logger),
          Checks::Command.call("orca-ide", required: false, recommendation: "install Orca CLI", runner: runner, env: env, logger: logger),
          Checks::Command.call("gh", required: false, recommendation: "install GitHub CLI", runner: runner, env: env, logger: logger)
        ]
        checks << Checks::Command.call("gh", args: ["auth", "status"], recommendation: "run gh auth login", runner: runner, env: env, logger: logger).merge(name: "gh-auth") if deploy
        checks
      end
      private_class_method :command_checks

      def thor_check
        require "thor"
        version = Gem.loaded_specs["thor"]&.version&.to_s
        { name: "thor", status: "ok", message: "Thor installed", version: version }.compact
      rescue LoadError => error
        { name: "thor", status: "error", message: "Thor is not installed: #{error.message}",
          recommendation: "run bundle install" }
      end
      private_class_method :thor_check

      def compose_check(runner:, env:, logger:)
        Checks::Command.call("docker", args: ["compose", "version"], required: false,
                             recommendation: "install Docker Compose v2", runner: runner, env: env, logger: logger).merge(name: "compose")
      end
      private_class_method :compose_check
    end
  end
end
