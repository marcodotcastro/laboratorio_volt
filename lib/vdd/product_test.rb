# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "time"

module Vdd
  module ProductTest
    COMPONENTS = %i[backend frontend].freeze
    TEST_COMMANDS = {
      backend: ["make", "test"],
      frontend: ["pnpm", "test"]
    }.freeze

    module_function

    def call(**kwargs)
      run_suite(**kwargs)
    end

    def run(**kwargs)
      run_suite(**kwargs)
    end

    def run_suite(context:, selection: :all, state_dir:, runner: Runner, env: ENV, on_event: nil)
      started_at = Time.now.utc.iso8601
      tests = selected_components(selection).map do |component|
        run_component(component, context: context, state_dir: state_dir, runner: runner, env: env, on_event: on_event)
      end
      summary = {
        issue: context.issue_id,
        status: tests.all? { |test| test[:status] == "success" } ? "success" : "error",
        started_at: started_at,
        finished_at: Time.now.utc.iso8601,
        errors: tests.filter_map { |test| test[:error] },
        tests: tests.map { |test| test.except(:stdout, :stderr, :runtime) }
      }
      summary[:summary_path] = write_summary(summary, context.issue_id, state_dir)
      summary
    end

    def render(summary)
      lines = ["component  status   duration  command  log"]
      lines << "---------  -------  --------  -------  ---"
      summary.fetch(:tests).each do |test|
        lines << format("%-9s  %-7s  %8.3fs  %-7s  %s", test[:component], test[:status],
                        test[:duration], test[:command].join(" "), test[:log_file])
      end
      lines << "product tests: #{summary.fetch(:status)}"
      lines << "summary: #{summary.fetch(:summary_path)}"
      lines.join("\n")
    end

    def selected_components(selection)
      selection = selection.to_sym
      return COMPONENTS if selection == :all
      return [selection] if COMPONENTS.include?(selection)

      raise UsageError, "Unknown test selection #{selection.inspect}; use backend, frontend or all"
    end

    def run_component(component, context:, state_dir:, runner:, env:, on_event: nil)
      path = component_path(component, context)
      logger = Logging.start(context.issue_id, "test-#{component}", state_dir: state_dir)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      emit_event(on_event, logger, "progress", "test.#{component}.validate_contract", "running",
                 "Checking #{component} test contract")

      validation_error = validate_contract(component, path)
      if validation_error
        emit_event(on_event, logger, "error", "test.#{component}.validate_contract", "error", validation_error)
        logger.finish("error:validation", action: "test.#{component}.finish", message: validation_error)
        return result_for(component, path, logger.path, started_at, status: "error", exit_status: EXIT_VALIDATION,
                          error: validation_error)
      end

      runtime = nil
      if component == :backend && File.executable?(File.join(path, "bin", "worktree-docker"))
        runtime = "bin/worktree-docker"
        emit_event(on_event, logger, "progress", "test.#{component}.check_runtime", "running",
                   "Checking #{runtime} runtime")
        probe = runner.run([File.join(path, runtime), "status", context.issue_number.to_s],
                           chdir: path, env: env, logger: logger)
        runtime_status = probe.success? ? "success" : "error"
        emit_event(on_event, logger, runtime_status, "test.#{component}.check_runtime", runtime_status,
                   "#{runtime} runtime #{probe.success? ? "ready" : "unavailable"}", duration: probe.duration)
      end

      command = TEST_COMMANDS.fetch(component)
      emit_event(on_event, logger, "progress", "test.#{component}.run", "running",
                 "Running #{command.join(" ")}")
      command_env = component == :frontend ? frontend_env(path, env, logger) : env
      command_result = runner.run(command, chdir: path, env: command_env, logger: logger)
      status = command_result.success? ? "success" : "error"
      error = command_result.success? ? nil : failure_message(component, command_result)
      emit_event(on_event, logger, status, "test.#{component}.run", status,
                 status == "success" ? "#{component.capitalize} tests passed" : error,
                 duration: command_result.duration)
      logger.finish(status, action: "test.#{component}.finish",
                    message: status == "success" ? "#{component.capitalize} tests passed" : error)
      result_for(component, path, logger.path, started_at, status: status,
                 exit_status: command_result.status, error: error, runtime: runtime,
                 duration: command_result.duration)
    rescue Errno::ENOENT => error
      emit_event(on_event, logger, "error", "test.#{component}.run", "error", error.message)
      logger&.finish("error:dependency", action: "test.#{component}.finish", message: error.message)
      result_for(component, path, logger&.path, started_at, status: "error", exit_status: 127,
                 error: error.message)
    end

    def component_path(component, context)
      component == :backend ? context.backend_path : context.frontend_path
    end
    private_class_method :component_path

    def validate_contract(component, path)
      return "#{component} worktree is not configured" if path.to_s.empty?
      return "#{component} worktree does not exist: #{path}" unless File.directory?(path)

      if component == :backend
        return "backend Makefile is missing: #{File.join(path, "Makefile")}" unless File.file?(File.join(path, "Makefile"))
      else
        package_path = File.join(path, "package.json")
        return "frontend package.json is missing: #{package_path}" unless File.file?(package_path)
        package = JSON.parse(File.read(package_path))
        return "frontend package.json has no test script" unless package.dig("scripts", "test")
        return "frontend pnpm-lock.yaml is missing" unless File.file?(File.join(path, "pnpm-lock.yaml"))
      end
      nil
    rescue JSON::ParserError => error
      "frontend package.json is invalid: #{error.message}"
    end
    private_class_method :validate_contract

    def frontend_env(path, env, _logger)
      package = JSON.parse(File.read(File.join(path, "package.json")))
      package_manager = package["packageManager"]
      env.to_h.merge("COREPACK_ENABLE_PROJECT_SPEC" => "1")
    rescue JSON::ParserError
      env
    end
    private_class_method :frontend_env

    def emit_event(callback, logger, event, action, status, message, duration: nil)
      record = { event: event, action: action, status: status, message: message, details: {} }
      record[:duration] = duration if duration
      logger&.event(**record)
      callback&.call(**record)
    end
    private_class_method :emit_event

    def failure_message(component, result)
      detail = result.stderr.to_s.strip
      detail = "exit #{result.status}" if detail.empty?
      "#{component} tests failed: #{detail}"
    end
    private_class_method :failure_message

    def result_for(component, path, log_file, started_at, status:, exit_status:, error: nil, runtime: nil, duration: nil)
      {
        component: component.to_s,
        command: TEST_COMMANDS.fetch(component),
        path: path,
        log_file: log_file,
        duration: duration || (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at),
        status: status,
        exit_status: exit_status,
        error: error,
        runtime: runtime
      }.compact
    end
    private_class_method :result_for

    def write_summary(summary, issue_id, state_dir)
      directory = Pathname.new(state_dir.to_s).join("runtime", issue_id.to_s)
      FileUtils.mkdir_p(directory)
      path = directory.join("tests.json")
      File.open(path, "w", 0o600) { |file| file.write(JSON.pretty_generate(summary)) }
      File.chmod(0o600, path)
      path.to_s
    end
    private_class_method :write_summary
  end
end
