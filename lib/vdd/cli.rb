# frozen_string_literal: true

require "json"
require "pathname"
require "stringio"
require "thor"

module Vdd
  class CLI < Thor
    class << self
      attr_accessor :exit_code
    end
    self.exit_code = EXIT_SUCCESS

    def self.start(given_args = ARGV, config = {})
      super(given_args, config.merge(debug: true))
    end

    desc "issue [ACTION] [NUMBER]", "Create or destroy an issue workspace"
    long_desc <<~HELP, wrap: false
      Create or destroy the complete development unit for one issue.

      Actions:
        vdd issue create NUMBER [--type bug|feature|improvement]
        vdd issue destroy [NUMBER]

      Short aliases:
        -c               alias for create
        -d               alias for destroy
        -t, --type       b=bug, f=feature, i=improvement

      The type defaults to improvement. Create produces fix/ccNUM-bug for bugs
      and feat/ccNUM-feature or feat/ccNUM-improvement for the other types.
      Destroy can use NUMBER, --issue/-i NUMBER, or the current workspace
      context when no number is supplied.

      Examples:
        vdd issue -c 2001 -t i
        vdd issue create 2001 --type bug
        vdd issue -d 2001
        vdd issue destroy --issue 2001
    HELP
    method_option :issue, type: :string, aliases: "-i", desc: "Issue number or CC-NUM"
    method_option :type, type: :string, aliases: "-t", default: "improvement",
                   desc: "Issue type: bug, feature, or improvement"
    method_option :json, type: :boolean, default: false
    method_option :quiet, type: :boolean, default: false
    method_option :dry_run, type: :boolean, default: false
    def issue(action = nil, number = nil)
      action = action.to_s
      raise UsageError, "Usage: vdd issue create NUMBER or vdd issue destroy [NUMBER]" unless %w[create destroy].include?(action)

      issue_value = number || options[:issue]
      issue_value = Context.resolve.issue_id if issue_value.nil? && action == "destroy"
      if action == "create"
        raise UsageError, "An issue number is required for issue create" unless issue_value
        issue_id = Context.normalize_issue(issue_value)
      else
        issue_id = Context.normalize_issue(issue_value)
      end
      issue_command(action, issue_id, options)
    rescue Vdd::Error => error
      self.class.report_error(error, options)
    end

    command_descriptions = {
      "up" => "Start the integrated issue runtime",
      "down" => "Stop the issue runtime and preserve its data",
      "restart" => "Restart the issue runtime and preserve its data",
      "reset" => "Rebuild issue Docker state without removing worktrees",
      "test" => "Run backend and frontend product tests",
      "doctor" => "Diagnose local and product toolchains",
      "deploy" => "Validate and open pull requests for changed repositories",
      "list" => "List all issue workspaces"
    }.freeze

    %w[up down restart reset test doctor deploy].each do |command|
      desc command, command_descriptions.fetch(command)
      method_option :issue, type: :string, aliases: "-i"
      method_option :json, type: :boolean, default: false
      method_option :quiet, type: :boolean, default: false
      method_option :dry_run, type: :boolean, default: false
      if command == "test"
        method_option :backend, type: :boolean, default: false, desc: "Run CRM backend tests only"
        method_option :frontend, type: :boolean, default: false, desc: "Run All In One frontend tests only"
        method_option :all, type: :boolean, default: false, desc: "Run both product test suites"
      end
      method_option :provider, type: :string, desc: "AI provider: codex, claude, antigravity, or gemini" if command == "deploy"
      if command == "deploy"
        long_desc <<~HELP, wrap: false
          Validate the backend and frontend product branches. Only product
          repositories with commits ahead of their base branch receive a push and PR;
          the Workspace coordinator never receives a deploy PR.

          PR descriptions are generated from repository changes by one of:
          codex, claude, antigravity, or gemini. The first deploy with changes
          asks for a provider and saves it for later deploys.

          Examples:
            vdd deploy --dry-run
            vdd deploy --provider codex
        HELP
      end
      if command == "doctor"
        long_desc <<~HELP, wrap: false
          Diagnose local and product toolchains without changing them.

          Use --fix to let the configured AI provider repair failed toolchains.
          The repair is limited to local dependencies and configuration; it must
          not edit product source, create commits, push branches, or open PRs.

          Examples:
            vdd doctor
            vdd doctor --fix
            vdd doctor --fix --json
        HELP
        method_option :fix, type: :boolean, default: false,
                      desc: "Repair failed toolchains with the configured AI provider"
      end
      method_option :deploy, type: :boolean, default: false if command == "doctor"
      define_method(command) do
        execute(command, options[:issue], options)
      rescue Vdd::Error => error
        self.class.report_error(error, options)
      end
    end

    desc "status [ISSUE]", "Summarize issue and repository state"
    method_option :issue, type: :string, aliases: "-i"
    method_option :json, type: :boolean, default: false
    method_option :quiet, type: :boolean, default: false
    def status(issue_value = nil)
      execute("status", issue_value || options[:issue], options)
    rescue Vdd::Error => error
      self.class.report_error(error, options)
    end

    desc "list", "List all issue workspaces"
    method_option :json, type: :boolean, default: false
    method_option :quiet, type: :boolean, default: false
    def list
      execute("list", nil, options)
    rescue Vdd::Error => error
      self.class.report_error(error, options)
    end

    desc "diff", "Summarize repository changes"
    method_option :issue, type: :string, aliases: "-i"
    method_option :json, type: :boolean, default: false
    method_option :quiet, type: :boolean, default: false
    method_option :full, type: :boolean, default: false, desc: "Include patch contents"
    def diff
      execute("diff", options[:issue], options)
    rescue Vdd::Error => error
      self.class.report_error(error, options)
    end

    desc "logs", "List issue execution logs"
    method_option :issue, type: :string, aliases: "-i"
    method_option :json, type: :boolean, default: false
    method_option :quiet, type: :boolean, default: false
    method_option :follow, type: :boolean, default: false, desc: "Follow the latest log"
    def logs
      execute("logs", options[:issue], options)
    rescue Vdd::Error => error
      self.class.report_error(error, options)
    end

    desc "install", "Install the vdd command in ~/.local/bin"
    method_option :json, type: :boolean, default: false
    method_option :quiet, type: :boolean, default: false
    method_option :dry_run, type: :boolean, default: false
    method_option :force, type: :boolean, default: false, desc: "Replace a conflicting symlink"
    def install
      self.class.install_command(options)
    rescue Vdd::Error => error
      self.class.report_error(error, options)
    end

    desc "config KEY [VALUE]", "Read or update VDD configuration"
    long_desc <<~HELP, wrap: false
      Configure the AI provider used by deploy. Supported providers are codex,
      claude, antigravity, and gemini.

      Examples:
        vdd config ai-provider
        vdd config ai-provider codex
        vdd config ai-provider claude
        vdd config ai-provider antigravity
        vdd config ai-provider gemini
    HELP
    method_option :json, type: :boolean, default: false
    method_option :quiet, type: :boolean, default: false
    def config(key = nil, value = nil)
      self.class.config_command(key, value, options)
    rescue Vdd::Error => error
      self.class.report_error(error, options)
    end

    def self.normalize_argv(argv)
      normalized = argv.dup
      if normalized.length == 2 && %w[-h --help].include?(normalized.last)
        return ["help", normalized.first] unless normalized.first == "help"
      end
      if normalized.length == 2 && normalized.first == "issue" && normalized.last == "help"
        return ["help", "issue"]
      end
      issue_index = normalized.index("issue")
      return normalized unless issue_index

      command_index = issue_index + 1
      if %w[-c -d].include?(normalized[command_index])
        normalized[command_index] = normalized[command_index] == "-c" ? "create" : "destroy"
      end
      normalized.each_with_index do |argument, index|
        normalized[index] = "--type" if argument == "-t"
        if normalized[index - 1] == "--type"
          normalized[index] = { "b" => "bug", "f" => "feature", "i" => "improvement" }.fetch(argument, argument)
        end
      end
      normalized
    end

    def self.execute(command, issue_value, opts)
      issue_id = Context.normalize_issue(issue_value) if issue_value
      context = if command == "list"
        nil
      elsif command == "status" && issue_id.nil?
        Context.resolve(allow_missing: true)
      elsif command == "status"
        Context.resolve(issue: issue_id, allow_issue_override: true)
      elsif command == "doctor" && issue_id.nil?
        begin
          Context.resolve
        rescue ContextError
          nil
        end
      else
        Context.resolve(issue: issue_id)
      end
      execution_state_dir = context ? context_state_dir(context) : Context.state_dir
      logger = Logging.start(context&.issue_id || "workspace", command, state_dir: execution_state_dir)
      reporter = Reporter.new(command: command, issue: context&.issue_id, json: option(opts, :json), quiet: option(opts, :quiet), logger: logger)
      reporter.progress(action: "#{command}.validate_context", message: "Checking issue context", details: { display: "audit" })
      if command == "list"
        reporter.progress(action: "list.collect_workspaces", message: "Reading issue workspaces")
        result = Commands::List.call(state_dir: execution_state_dir, runner: Runner, env: ENV, logger: logger)
        reporter.details(Commands::List.render(result))
        reporter.result(result, summary: list_summary(result))
        self.exit_code = EXIT_SUCCESS
      elsif command == "status" && (context.nil? || !context.workspace_available?)
        reporter.progress(action: "status.check_workspace", message: "Checking issue workspace availability")
        result = Commands::Status.empty(issue: context&.issue_id)
        reporter.details(Commands::Status.render(result))
        reporter.result(result, summary: "No issue workspace available")
        self.exit_code = EXIT_SUCCESS
      elsif command == "doctor"
        reporter.progress(action: "doctor.check_toolchains", message: "Checking local toolchains")
        result = if option(opts, :fix)
          reporter.progress(action: "doctor.repair_toolchains", message: "Repairing failed toolchains")
          Commands::DoctorFix.call(context: context, root: context&.workspace_path || Dir.pwd,
                                   deploy: option(opts, :deploy), runner: Runner, env: ENV, logger: logger,
                                   state_dir: execution_state_dir)
        else
          Commands::Doctor.call(context: context, root: context&.workspace_path || Dir.pwd,
                                deploy: option(opts, :deploy), runner: Runner, env: ENV, logger: logger)
        end
        reporter.details(Commands::Doctor.render(result))
        reporter.result(result, summary: "Local toolchains checked",
                        next_action: result[:errors].empty? ? nil : "Fix the reported dependency and retry")
        self.exit_code = result.fetch(:exit_code, result[:errors].empty? ? EXIT_SUCCESS : EXIT_DEPENDENCY)
      elsif command == "deploy"
        reporter.progress(action: "deploy.inspect_worktrees", message: "Checking product worktrees")
        result = Commands::Deploy.call(context: context, state_dir: execution_state_dir,
                                        dry_run: option(opts, :dry_run), provider: option(opts, :provider),
                                        runner: Runner, env: ENV, logger: logger,
                                        select_provider: -> { ask_deploy_provider(opts) },
                                        persist_provider: ->(selected) { AI::ProviderConfig.save(selected) },
                                        confirm: ->(selected, roles) { ask_deploy_confirmation(opts, selected, roles) })
        reporter.details(Commands::Deploy.render(result))
        reporter.result(result.except(:exit_code), summary: deploy_summary(result),
                        next_action: deploy_next_action(result))
        self.exit_code = result.fetch(:exit_code, EXIT_SUCCESS)
      elsif option(opts, :dry_run)
        reporter.result(status: "dry-run", phase: "validated", repositories: repositories(context),
                        summary: "Execution plan generated")
        self.exit_code = EXIT_SUCCESS
      elsif %w[up down restart reset].include?(command)
        result = Adapters::LegacyScripts.runtime(command, issue: context.issue_id, state_dir: execution_state_dir,
                                                 logger: logger, on_event: reporter.method(:event))
        if result.success?
          reporter.result(status: "success", phase: "completed", repositories: repositories(context),
                          summary: "#{command.capitalize} completed")
          reporter.info(issue_url(context))
          self.exit_code = EXIT_SUCCESS
        else
          message = command_cause(result.stderr, "#{command} exited with status #{result.status}")
          reporter.result(status: "error", phase: "failed", repositories: repositories(context), errors: [message],
                          summary: "#{command.capitalize} could not be completed",
                          next_action: "Check the detailed log and retry")
          self.exit_code = EXIT_PRODUCT
        end
      elsif command == "test"
        reporter.progress(action: "test.run_products", message: "Running product tests", details: { display: "audit" })
        result = Commands::Test.call(context: context, selection: test_selection(opts),
                                     state_dir: execution_state_dir, runner: Runner, env: ENV,
                                     on_event: reporter.method(:event))
        reporter.details(Commands::Test.render(result))
        reporter.result(result.merge(phase: "complete"),
                        summary: result[:status] == "success" ? "Product tests passed" : "Product tests failed",
                        next_action: result[:status] == "success" ? nil : "Fix the reported failures and retry")
        self.exit_code = result[:status] == "success" ? EXIT_SUCCESS : EXIT_PRODUCT
      elsif command == "status"
        reporter.progress(action: "status.collect_repositories", message: "Collecting repository state")
        result = Commands::Status.call(context: context, runner: Runner, env: ENV, logger: logger)
        reporter.details(Commands::Status.render(result))
        reporter.result(result, summary: "Issue status collected")
        reporter.info(issue_url(context))
        self.exit_code = EXIT_SUCCESS
      elsif command == "diff"
        reporter.progress(action: "diff.collect_changes", message: "Collecting repository changes")
        result = Commands::Diff.call(context: context, full: option(opts, :full), runner: Runner, env: ENV, logger: logger)
        reporter.details(Commands::Diff.render(result))
        reporter.result(result, summary: "Repository changes collected")
        self.exit_code = EXIT_SUCCESS
      elsif command == "logs"
        reporter.progress(action: "logs.read_history", message: "Reading issue logs")
        result = Commands::Logs.call(issue_id: context.issue_id, state_dir: execution_state_dir, exclude: logger.path)
        if option(opts, :follow) && result[:latest]
          follow_output = option(opts, :json) ? StringIO.new : $stdout
          Commands::Logs.follow(result[:latest], output: follow_output)
          result = Commands::Logs.call(issue_id: context.issue_id, state_dir: execution_state_dir, exclude: logger.path)
        end
        reporter.details(Commands::Logs.render(result)) unless option(opts, :follow) && !option(opts, :json)
        reporter.result(result, summary: "Issue logs read")
        self.exit_code = EXIT_SUCCESS
      else
        reporter.result(status: "not-implemented", phase: "validated", repositories: repositories(context),
                        summary: "Command not implemented")
        self.exit_code = EXIT_SUCCESS
      end
    end

    def self.issue_command(action, issue_id, opts)
      command = "issue #{action}"
      type = Context.normalize_type(option(opts, :type) || "improvement")
      logger = Logging.start(issue_id, command, state_dir: state_dir)
      reporter = Reporter.new(command: command, issue: issue_id, json: option(opts, :json), quiet: option(opts, :quiet), logger: logger)
      reporter.progress(action: "issue.validate_context", message: "Checking issue context", details: { display: "audit" })
      if option(opts, :dry_run)
        reporter.result(status: "dry-run", phase: "validated", summary: "No changes made")
        self.exit_code = EXIT_SUCCESS
        return
      end

      result = if action == "create"
        Adapters::LegacyScripts.issue_create(issue_id, type: type, state_dir: state_dir, logger: logger,
                                             on_event: reporter.method(:event))
      else
        confirmation = ask_destroy_confirmation(issue_id, opts)
        Adapters::LegacyScripts.issue_destroy(issue_id, state_dir: state_dir, logger: logger,
                                              confirmation: confirmation, on_event: reporter.method(:event))
      end
      if result.success?
        summary = action == "create" ? "Issue workspace ready" : "Issue workspace removed"
        reporter.result(status: "success", phase: "completed", summary: summary)
        self.exit_code = EXIT_SUCCESS
      else
        message = command_cause(result.stderr, "#{command} exited with status #{result.status}")
        reporter.result(status: "error", phase: "failed", errors: [message],
                        summary: "#{command.capitalize} could not be completed",
                        next_action: "Check the detailed log and retry")
        self.exit_code = EXIT_PRODUCT
      end
    end

    def self.install_command(opts)
      logger = Logging.start("workspace", "install", state_dir: install_state_dir)
      reporter = Reporter.new(command: "install", issue: nil, json: option(opts, :json),
                              quiet: option(opts, :quiet), logger: logger)
      result = Installer.call(
        executable_path: File.expand_path("../../bin/vdd", __dir__),
        home: ENV.fetch("HOME"),
        env: ENV,
        dry_run: option(opts, :dry_run),
        force: option(opts, :force),
        on_event: reporter.method(:event)
      )
      details = {
        "Link" => result[:link],
        "Target" => result[:target],
        "PATH" => result[:path_configured] ? "configured" : result[:recommendation]
      }
      details["Impact"] = result[:impact] if result[:impact]
      reporter.result(result.except(:exit_code), summary: install_summary(result), details: details,
                      next_action: result[:next_action])
      self.exit_code = result.fetch(:exit_code, EXIT_SUCCESS)
    end

    def self.config_command(key, value, opts)
      raise UsageError, "Usage: vdd config ai-provider [codex|claude|antigravity|gemini]" unless key == "ai-provider"

      logger = Logging.start("workspace", "config", state_dir: install_state_dir)
      reporter = Reporter.new(command: "config", issue: nil, json: option(opts, :json),
                              quiet: option(opts, :quiet), logger: logger)
      reporter.progress(action: "config.validate", message: "Checking AI provider configuration")
      action = value ? "config.save" : "config.read"
      reporter.progress(action: action,
                        message: value ? "Saving AI provider" : "Reading configured AI provider")
      begin
        provider = value ? AI::ProviderConfig.save(value) : AI::ProviderConfig.load
      rescue Vdd::Error => error
        reporter.failure(action: action, message: "Could not update configuration",
                         details: { error: error.message })
        reporter.result(status: "error", phase: "failed", errors: [error.message],
                        summary: "Configuration could not be completed",
                        next_action: "Use codex, claude, antigravity, or gemini and retry")
        self.exit_code = error.code
        return
      end
      reporter.success(action: action,
                       message: value ? "AI provider saved" : "AI provider read")
      payload = { command: "config", key: key, provider: provider, status: "success", errors: [] }
      summary = provider ? "AI provider configured" : "AI provider not configured"
      reporter.result(payload, summary: summary, details: { "Provider" => provider || "not configured" })
      self.exit_code = EXIT_SUCCESS
    end

    def self.repositories(context)
      {
        workspace: { path: context.workspace_path, branch: context.issue_branch },
        backend: { path: context.backend_path, branch: context.issue_branch },
        frontend: { path: context.frontend_path, branch: context.issue_branch }
      }
    end

    def self.report_error(error, opts, phase: "validation")
      if option(opts, :json)
        $stdout.puts JSON.generate(command: nil, issue: nil, status: "error", phase: phase,
                                   repositories: {}, log_file: nil, errors: [error.message], events: [])
      elsif !option(opts, :quiet)
        $stderr.puts "✗ Command could not be started"
        $stderr.puts "Cause: #{error.message}"
        $stderr.puts "Next step: use the command form shown in the error message"
      end
      self.exit_code = error.code
    end

    def self.option(opts, name)
      opts[name] || opts[name.to_s]
    end

    def self.test_selection(opts)
      return :all if option(opts, :all) || (!option(opts, :backend) && !option(opts, :frontend))
      return :backend if option(opts, :backend) && !option(opts, :frontend)
      return :frontend if option(opts, :frontend) && !option(opts, :backend)

      :all
    end

    def self.ask_destroy_confirmation(issue_id, opts)
      number = issue_id.delete_prefix("CC-")
      $stderr.print "Confirm destruction of issue #{issue_id}. Type #{number} again to continue: " unless option(opts, :quiet)
      $stderr.flush
      $stdin.gets
    end

    def self.ask_deploy_provider(opts)
      $stderr.print "Choose AI provider for PR descriptions (codex/claude/antigravity/gemini): " unless option(opts, :quiet)
      $stderr.flush
      AI::Provider.normalize($stdin.gets.to_s)
    end

    def self.ask_deploy_confirmation(opts, provider, roles)
      repositories = roles.map(&:to_s).join(", ")
      $stderr.print "Use #{provider} to describe #{repositories} and open pull requests? Type yes to confirm: " unless option(opts, :quiet)
      $stderr.flush
      %w[y yes].include?($stdin.gets.to_s.strip.downcase)
    end

    def self.state_dir
      ENV["WORKSPACE_STATE_DIR"] || File.join(Dir.pwd, ".workspace")
    end

    def self.context_state_dir(context)
      return state_dir if ENV["WORKSPACE_STATE_DIR"]

      Pathname.new(context.manifest_path).dirname.dirname.to_s
    end

    def self.issue_url(context)
      "http://cc#{context.issue_number}.localhost"
    end

    def self.install_state_dir
      ENV["WORKSPACE_STATE_DIR"] || File.expand_path("../../.workspace", __dir__)
    end

    def self.install_summary(result)
      {
        "installed" => "VDD installed",
        "already_installed" => "VDD already installed",
        "dry-run" => "No changes made",
        "error" => "Installation could not be completed"
      }.fetch(result[:status], Reporter::HUMAN_STATUSES.fetch(result[:status].to_s, "Command completed"))
    end

    def self.list_summary(result)
      result[:status] == "no-workspaces" ? "No issue workspaces available" : "Issue workspaces listed"
    end

    def self.deploy_summary(result)
      {
        "no-changes" => "No changes to publish",
        "dry-run" => "Deploy plan generated",
        "success" => "Pull requests published",
        "error" => "Deploy could not be completed"
      }.fetch(result[:status], "Deploy completed")
    end

    def self.deploy_next_action(result)
      return unless result[:status] == "error"

      if Array(result[:errors]).any? { |error| error.to_s.include?("commit") || error.to_s.include?("dirty") }
        "Commit the changes manually and retry deploy"
      else
        "Fix the reported dependency and retry"
      end
    end

    def self.command_cause(stderr, fallback)
      lines = stderr.to_s.lines.map(&:strip).reject(&:empty?)
      cause = lines.find { |line| line.start_with?("Cause:") || line.start_with?("Causa:") }
      cause ||= lines.reverse.find { |line| line.start_with?("ERROR:") }
      return fallback unless cause

      cause.sub(/\A(?:Cause|Causa|ERROR):\s*/, "").strip
    end

    private

    def execute(command, issue_value, opts)
      self.class.execute(command, issue_value, opts)
    end

    def issue_command(action, issue_id, opts)
      self.class.issue_command(action, issue_id, opts)
    end
  end
end
