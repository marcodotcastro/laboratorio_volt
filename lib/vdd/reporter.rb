# frozen_string_literal: true

require "json"

module Vdd
  class Reporter
    EVENT_MARKERS = {
      "start" => "→",
      "progress" => "→",
      "success" => "✓",
      "warning" => "!",
      "error" => "✗"
    }.freeze

    STATUS_MARKERS = {
      "error" => "✗",
      "warning" => "!"
    }.freeze

    HUMAN_STATUSES = {
      "installed" => "VDD installed",
      "already_installed" => "VDD already installed",
      "dry-run" => "No changes made",
      "success" => "Command completed",
      "warning" => "Command completed with warnings",
      "error" => "Command could not be completed",
      "no-workspace" => "No issue workspace available",
      "no-workspaces" => "No issue workspaces available",
      "no-changes" => "No changes to publish"
    }.freeze

    DISPLAY_ACTIONS = {
      "issue.prepare_crm_source" => { resource: "CRM", scope: "persistent source", progress: "updating", success: "ready", error: "could not prepare" },
      "issue.prepare_frontend_source" => { resource: "All In One", scope: "persistent source", progress: "updating", success: "ready", error: "could not prepare" },
      "issue.fetch_crm_source" => { resource: "CRM", scope: "persistent source", progress: "updating", success: "ready", error: "failed" },
      "issue.clone_crm_source" => { resource: "CRM", scope: "persistent source", progress: "updating", success: "ready", error: "failed" },
      "issue.fetch_aio_source" => { resource: "All In One", scope: "persistent source", progress: "updating", success: "ready", error: "failed" },
      "issue.clone_aio_source" => { resource: "All In One", scope: "persistent source", progress: "updating", success: "ready", error: "failed" },
      "issue.sync_skills" => { resource: "Workspace", scope: "skills", progress: "syncing", success: "ready", error: "failed" },
      "issue.register_workspace" => { resource: "Workspace", scope: "repository", progress: "checking", success: "ready", error: "failed" },
      "issue.add_workspace" => { resource: "Workspace", scope: "repository", progress: "adding", success: "ready", error: "failed" },
      "issue.find_coordinator" => { resource: "Workspace", scope: "coordinator", progress: "checking", success: "ready", error: "could not find" },
      "issue.create_coordinator" => { resource: "Workspace", scope: "coordinator", progress: "creating", success: "ready", error: "could not create" },
      "issue.align_coordinator" => { resource: "Workspace", scope: "coordinator", progress: "aligning", success: "aligned", error: "could not align" },
      "issue.verify_coordinator" => { resource: "Workspace", scope: "coordinator", progress: "checking", success: "ready", error: "could not verify" },
      "issue.create_backend_worktree" => { resource: "Backend", scope: "issue worktree", progress: "creating", success: "ready", error: "could not create" },
      "issue.create_frontend_worktree" => { resource: "Frontend", scope: "issue worktree", progress: "creating", success: "ready", error: "could not create" },
      "issue.reuse_backend_worktree" => { resource: "Backend", scope: "issue worktree", progress: "reusing", success: "ready", error: "could not reuse" },
      "issue.reuse_frontend_worktree" => { resource: "Frontend", scope: "issue worktree", progress: "reusing", success: "ready", error: "could not reuse" },
      "destroy.clean_runtime" => { resource: "Runtime", scope: "state", progress: "removing", success: "removed", error: "could not remove" },
      "destroy.remove_backend_worktree" => { resource: "Backend", scope: "issue worktree", progress: "removing", success: "removed", error: "could not remove" },
      "destroy.remove_frontend_worktree" => { resource: "Frontend", scope: "issue worktree", progress: "removing", success: "removed", error: "could not remove" },
      "destroy.remove_coordinator" => { resource: "Workspace", scope: "coordinator", progress: "removing", success: "removed", error: "could not remove" },
      "destroy.inspect_coordinator" => { resource: "Workspace", scope: "coordinator", progress: "checking", success: "ready", error: "could not inspect" },
      "destroy.find_coordinator" => { resource: "Workspace", scope: "coordinator", progress: "checking", success: "ready", error: "could not find" },
      "destroy.preserve_state" => { resource: "Workspace", scope: "issue state", progress: "preserving", success: "preserved", error: "could not preserve" },
      "runtime.check_compose" => { resource: "Runtime", scope: "Compose", progress: "checking", success: "ready", error: "not available" },
      "runtime.start" => { resource: "Runtime", scope: "containers", progress: "starting", success: "ready", error: "could not start" },
      "runtime.stop" => { resource: "Runtime", scope: "containers", progress: "stopping", success: "stopped", error: "could not stop" },
      "runtime.restart" => { resource: "Runtime", scope: "containers", progress: "restarting", success: "ready", error: "could not restart" },
      "runtime.reset_state" => { resource: "Runtime", scope: "state", progress: "resetting", success: "reset", error: "could not reset" },
      "runtime.rebuild" => { resource: "Runtime", scope: "containers", progress: "rebuilding", success: "ready", error: "could not rebuild" },
      "runtime.destroy" => { resource: "Runtime", scope: "state", progress: "removing", success: "removed", error: "could not remove" },
      "runtime.check_services" => { resource: "Runtime", scope: "services", progress: "checking", success: "ready", error: "not ready" },
      "runtime.prepare_account" => { resource: "Runtime", scope: "account", progress: "preparing", success: "ready", error: "could not prepare" },
      "runtime.register_proxy" => { resource: "Runtime", scope: "proxy", progress: "registering", success: "ready", error: "could not register" },
      "runtime.unregister_proxy" => { resource: "Runtime", scope: "proxy", progress: "removing", success: "removed", error: "could not remove" },
      "runtime.check_endpoints" => { resource: "Runtime", scope: "endpoints", progress: "checking", success: "ready", error: "not ready" },
      "install.validate_target" => { resource: "Installation", scope: "target", progress: "checking", success: "valid", error: "invalid" },
      "install.check_link" => { resource: "Installation", scope: "link", progress: "checking", success: "ready", error: "not available" },
      "install.create_link" => { resource: "Installation", scope: "link", progress: "creating", success: "ready", warning: "planned", error: "could not create" },
      "install.check_path" => { resource: "Installation", scope: "PATH", progress: "checking", success: "ready", warning: "not configured", error: "not configured" },
      "config.validate" => { resource: "AI provider", scope: "configuration", progress: "checking", success: "valid", error: "invalid" },
      "config.save" => { resource: "AI provider", scope: "configuration", progress: "saving", success: "saved", error: "could not save" },
      "config.read" => { resource: "AI provider", scope: "configuration", progress: "reading", success: "ready", error: "could not read" },
      "list.collect_workspaces" => { resource: "Issue workspaces", scope: "state", progress: "reading", success: "ready", error: "could not read" },
      "status.check_workspace" => { resource: "Workspace", scope: "availability", progress: "checking", success: "ready", error: "not available" },
      "status.collect_repositories" => { resource: "Repositories", scope: "state", progress: "collecting", success: "ready", error: "could not collect" },
      "doctor.check_toolchains" => { resource: "Local toolchains", scope: "dependencies", progress: "checking", success: "ready", error: "not ready" },
      "doctor.repair_toolchains" => { resource: "Local toolchains", scope: "dependencies", progress: "repairing", success: "ready", error: "could not repair" },
      "deploy.inspect_worktrees" => { resource: "Repositories", scope: "changes", progress: "checking", success: "ready", error: "could not inspect" },
      "test.backend.validate_contract" => { resource: "Backend", scope: "test contract", progress: "checking", success: "ready", error: "invalid" },
      "test.backend.check_runtime" => { resource: "Backend", scope: "runtime", progress: "checking", success: "ready", error: "not available" },
      "test.backend.run" => { resource: "Backend", scope: "tests", progress: "running", success: "passed", error: "failed" },
      "test.frontend.validate_contract" => { resource: "Frontend", scope: "test contract", progress: "checking", success: "ready", error: "invalid" },
      "test.frontend.run" => { resource: "Frontend", scope: "tests", progress: "running", success: "passed", error: "failed" },
      "diff.collect_changes" => { resource: "Repositories", scope: "changes", progress: "collecting", success: "ready", error: "could not collect" },
      "logs.read_history" => { resource: "Logs", scope: "history", progress: "reading", success: "ready", error: "could not read" }
    }.freeze

    attr_reader :payload

    def initialize(command:, issue:, json: false, quiet: false, logger: nil, output: $stdout, error_output: $stderr)
      @command = command
      @json = json
      @quiet = quiet
      @logger = logger
      @output = output
      @error_output = error_output
      @last_human_line = nil
      @payload = {
        command: command,
        issue: issue,
        status: "pending",
        phase: nil,
        repositories: { workspace: nil, backend: nil, frontend: nil },
        log_file: logger&.path,
        errors: [],
        events: []
      }
      print_header
    end

    def event(event:, action:, status:, message:, details: {}, duration: nil)
      record = {
        event: event.to_s,
        action: action.to_s,
        status: status.to_s,
        message: message.to_s
      }
      record[:duration] = duration if duration
      normalized_details = symbolize(details)
      record[:details] = normalized_details unless normalized_details.empty?
      @payload[:events] << record
      log_event(record)
      print_event(record) unless @json || @quiet || record[:event] == "finish"
      record
    end

    def progress(action:, message:, details: {})
      event(event: "progress", action: action, status: "running", message: message, details: details)
    end

    def success(action:, message:, details: {}, duration: nil)
      event(event: "success", action: action, status: "success", message: message, details: details, duration: duration)
    end

    def warning(action:, message:, details: {}, duration: nil)
      event(event: "warning", action: action, status: "warning", message: message, details: details, duration: duration)
    end

    def failure(action:, message:, details: {}, duration: nil)
      event(event: "error", action: action, status: "error", message: message, details: details, duration: duration)
    end

    # Kept for callers that have not migrated to named actions yet.
    def phase(message)
      @payload[:phase] = message
      progress(action: "legacy.progress", message: message)
    end

    # Kept for detail renderers that are migrated independently from the CLI.
    def info(message)
      @output.puts(message) if human_output?
    end

    def details(text)
      return unless human_output?

      @output.puts("Details")
      @output.puts(text.to_s)
      flush(@output)
    end

    def result(values = {}, summary: nil, details: {}, next_action: nil, **keyword_values)
      values = values.merge(keyword_values)
      merge_result(values)
      @payload[:status] = "success" if @payload[:status] == "pending"
      summary ||= human_status(@payload.fetch(:status))
      finish_details = symbolize(details)
      finish_details[:next_action] = next_action if next_action
      finish_event = finish_record(summary, finish_details)
      @payload[:events] << finish_event
      log_finish(finish_event)
      render_summary(summary, symbolize(details), next_action)
      @json ? @output.puts(JSON.generate(@payload)) : nil
      @payload
    end

    def error(message, code: EXIT_VALIDATION)
      @payload[:status] = "error"
      @payload[:errors] = Array(@payload[:errors]) + [message]
      @payload[:phase] ||= "error"
      failure(action: "#{@command}.error", message: message)
      result(status: "error", phase: @payload[:phase],
             summary: human_status("error"))
      code
    end

    private

    def print_header
      return unless human_output?

      @output.puts("vdd #{@command}")
      @output.puts("Detailed log: #{@logger.path}") if @logger
      flush(@output)
    end

    def human_output?
      !@json && !@quiet
    end

    def print_event(record)
      return if audit_only?(record)

      marker = EVENT_MARKERS.fetch(record[:event])
      stream = record[:event] == "error" ? @error_output : @output
      message = human_message(record)
      return if message.nil? || message.empty?

      line = "#{marker} #{message}"
      return if line == @last_human_line

      @last_human_line = line
      stream.puts(line)
      flush(stream)
    end

    def audit_only?(record)
      details = symbolize(record[:details] || {})
      (details[:display].to_s == "audit" && %w[progress success].include?(record[:event].to_s)) ||
        record[:action].to_s.end_with?(".legacy_progress")
    end

    def human_message(record)
      action = record[:action].to_s
      return if %w[start finish].include?(record[:event].to_s)

      labels = DISPLAY_ACTIONS[action]
      labels ||= generic_labels(action)
      state = labels[record[:event].to_sym] || labels[:success]
      message = [labels[:resource], labels[:scope], state].compact.join(" · ")
      details = symbolize(record[:details] || {})
      outcome = details[:outcome].to_s
      message += " · #{outcome}" if record[:event].to_s == "success" && %w[created reused updated removed skipped].include?(outcome)
      message += " · #{format_duration(record[:duration])}" if record[:event].to_s != "progress" && record[:duration]
      message
    end

    def generic_labels(action)
      parts = action.split(".").reject(&:empty?)
      resource = titleize(parts[-2] || parts.first || "command")
      scope = titleize(parts.last || "operation").downcase
      { resource: resource, scope: scope, progress: "running", success: "completed", warning: "warning", error: "failed" }
    end

    def format_duration(duration)
      format("%.2fs", Float(duration))
    rescue ArgumentError, TypeError
      nil
    end

    def merge_result(values)
      result_values = symbolize(values)
      result_values.delete(:log_file) if result_values[:log_file].nil? && @payload[:log_file]
      existing_events = @payload[:events]
      @payload.merge!(result_values)
      @payload[:events] = existing_events
    end

    def finish_record(summary, details)
      record = {
        event: "finish",
        action: "#{command_action}.finish",
        status: @payload.fetch(:status).to_s,
        message: summary.to_s
      }
      record[:details] = details unless details.empty?
      record
    end

    def render_summary(summary, details, next_action)
      return unless human_output?

      stream = @payload[:status].to_s.start_with?("error") ? @error_output : @output
      stream.puts
      stream.puts("Result")
      stream.puts("#{summary_marker} #{summary}")
      render_errors(stream) if @payload[:status].to_s.start_with?("error")
      details.each { |label, value| stream.puts("#{label}: #{safe_value(value)}") }
      stream.puts("Next step: #{safe_value(next_action)}") if next_action
      flush(stream)
    end

    def render_errors(stream)
      Array(@payload[:errors]).each_with_index do |message, index|
        label = index.zero? ? "Cause" : "Detail"
        stream.puts("#{label}: #{safe_value(message)}")
      end
    end

    def summary_marker
      status = @payload.fetch(:status).to_s
      return STATUS_MARKERS.fetch(status) if STATUS_MARKERS.key?(status)
      return "✗" if status.start_with?("error")
      return "!" if status.start_with?("warning")

      "✓"
    end

    def human_status(status)
      HUMAN_STATUSES.fetch(status.to_s) { titleize(status) }
    end

    def command_action
      @command.to_s.downcase.gsub(/[^a-z0-9]+/, ".").gsub(/\A\.|\.\z/, "")
    end

    def titleize(value)
      value.to_s.tr("_", " ").tr("-", " ").split.map(&:capitalize).join(" ")
    end

    def safe_value(value)
      case value
      when Hash
        value.map { |key, item| "#{key}=#{safe_value(item)}" }.join(", ")
      when Array
        value.map { |item| safe_value(item) }.join(", ")
      else
        value.to_s
      end
    end

    def log_event(record)
      return unless @logger&.respond_to?(:event)

      @logger.event(**record)
    end

    def log_finish(record)
      return unless @logger

      if @logger.respond_to?(:finish_event)
        @logger.finish_event(**record)
      elsif @logger.respond_to?(:finish)
        @logger.finish(record[:status], action: record[:action], message: record[:message],
                       details: record[:details] || {})
      end
    end

    def symbolize(values)
      values.to_h.each_with_object({}) do |(key, value), result|
        result[key.to_sym] = value
      end
    end

    def flush(stream)
      stream.flush if stream.respond_to?(:flush)
    end
  end
end
