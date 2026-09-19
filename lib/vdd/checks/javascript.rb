# frozen_string_literal: true

require "json"
require "pathname"

module Vdd
  module Checks
    module Javascript
      REQUIRED_SCRIPTS = %w[test lint typecheck build].freeze
      TOOL_SCRIPTS = { "turbo" => /\bturbo\b/, "vitest" => /\bvitest\b/, "playwright" => /\bplaywright\b/ }.freeze

      module_function

      def call(path:, runner: Runner, env: ENV, logger: nil)
        root = Pathname.new(path.to_s)
        package_path = root.join("package.json")
        return [failure("package.json", "package.json not found: #{package_path}", "create package.json before running doctor")] unless package_path.file?

        package = JSON.parse(package_path.read)
        return [failure("package.json", "package.json must contain a JSON object", "fix package.json and run doctor again")] unless package.is_a?(Hash)
        scripts = package.fetch("scripts", {})
        return [failure("scripts", "scripts in package.json must be an object", "fix package.json and run doctor again")] unless scripts.is_a?(Hash)

        checks = [package_manager(package), engines(package), lockfile(root)]
        checks.concat(script_checks(scripts))
        checks.concat(tool_checks(package, runner: runner, env: env, logger: logger))
        checks
      rescue JSON::ParserError => error
        [failure("package.json", "package.json is invalid: #{error.message}", "fix package.json and run doctor again")]
      rescue Errno::EACCES => error
        [failure("package.json", "cannot read package.json: #{error.message}", "check package.json permissions")]
      end

      def package_manager(package)
        declaration = package["packageManager"].to_s
        return warning("packageManager", "packageManager is not declared", "declare packageManager, for example pnpm@10.0.0") if declaration.empty?
        return failure("packageManager", "unsupported packageManager #{declaration}", "declare a pnpm packageManager") unless declaration.start_with?("pnpm@")

        ok("packageManager", "packageManager declared: #{declaration}")
      end
      private_class_method :package_manager

      def engines(package)
        engines = package["engines"]
        return failure("engines", "engines in package.json must be an object", "fix package.json and run doctor again") unless engines.nil? || engines.is_a?(Hash)

        expected = engines&.fetch("node", "").to_s
        return warning("engines", "Node engines are not declared", "declare engines.node, for example >=22.13.0 <23") if expected.empty?

        ok("engines", "Node engine declared: #{expected}", details: { constraint: expected })
      end
      private_class_method :engines

      def lockfile(root)
        path = root.join("pnpm-lock.yaml")
        return ok("lockfile", "pnpm-lock.yaml found", details: { path: path.to_s }) if path.file?

        warning("lockfile", "pnpm-lock.yaml is missing", "run pnpm install in the product worktree")
      end
      private_class_method :lockfile

      def script_checks(scripts)
        REQUIRED_SCRIPTS.map do |name|
          if scripts.key?(name) && !scripts[name].to_s.empty?
            ok("script:#{name}", "script #{name} is declared")
          else
            warning("script:#{name}", "script #{name} is missing from package.json", "script #{name} ausente no package.json: execute doctor --json para detalhes")
          end
        end
      end
      private_class_method :script_checks

      def tool_checks(package, runner:, env:, logger:)
        scripts = package.fetch("scripts", {}).values.join(" ")
        dependencies = package.values_at("dependencies", "devDependencies", "optionalDependencies")
                              .select { |value| value.is_a?(Hash) }.reduce({}, :merge)
        TOOL_SCRIPTS.filter_map do |name, pattern|
          next unless scripts.match?(pattern)

          if dependencies.key?(name) || (name == "playwright" && dependencies.key?("@playwright/test"))
            ok(name, "#{name} dependency is declared")
          else
            failure(name, "#{name} is used by a package script but is not declared", "add #{name} to devDependencies")
          end
        end + command_checks(package, runner: runner, env: env, logger: logger)
      end
      private_class_method :tool_checks

      def command_checks(package, runner:, env:, logger:)
        declarations = package.fetch("packageManager", "").to_s
        expected = declarations.split("@", 2).last.to_s
        check = Command.call("node", recommendation: "install Node.js 22.13.0", runner: runner, env: env, logger: logger)
        if check[:status] == "ok" && package.dig("engines", "node")
          actual = parse_version(check[:version])
          unless actual && satisfies?(actual, package.dig("engines", "node"))
            check = check.merge(status: "error", message: "Node #{actual&.join(".") || check[:version]} does not satisfy #{package.dig("engines", "node")}", recommendation: "install a Node version matching engines.node")
          end
        end
        pnpm = Command.call("pnpm", required: !expected.empty?, recommendation: "install pnpm #{expected.empty? ? "10.0.0" : expected}", runner: runner, env: env, logger: logger)
        if pnpm[:status] == "ok" && !expected.empty? && parse_version(pnpm[:version]) != parse_version(expected)
          pnpm = pnpm.merge(status: "error", message: "pnpm #{pnpm[:version]} does not match packageManager pnpm@#{expected}", recommendation: "install pnpm #{expected}")
        end
        [check.merge(name: "node"), pnpm.merge(name: "pnpm")]
      end
      private_class_method :command_checks

      def satisfies?(actual, constraint)
        constraint.to_s.split.map do |part|
          operator = part[/\A(>=|<=|>|<|=)/, 1] || "="
          target = parse_version(part.sub(/\A(?:>=|<=|>|<|=)/, ""))
          next true unless target

          comparison = actual <=> target
          case operator
          when ">=" then comparison >= 0
          when "<=" then comparison <= 0
          when ">" then comparison.positive?
          when "<" then comparison.negative?
          else comparison.zero?
          end
        end.all?
      end
      private_class_method :satisfies?

      def parse_version(value)
        match = value.to_s.match(/(\d+)(?:\.(\d+))?(?:\.(\d+))?/)
        match && match.captures.filter_map { |part| part&.to_i }.then { |parts| parts.fill(0, parts.length...3) }
      end
      private_class_method :parse_version

      def ok(name, message, details: nil)
        { name: name, status: "ok", message: message, details: details }.compact
      end
      private_class_method :ok

      def warning(name, message, recommendation)
        { name: name, status: "warning", message: message, recommendation: recommendation }
      end
      private_class_method :warning

      def failure(name, message, recommendation)
        { name: name, status: "error", message: message, recommendation: recommendation }
      end
      private_class_method :failure
    end
  end
end
