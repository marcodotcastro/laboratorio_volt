# frozen_string_literal: true

require "fileutils"

module Vdd
  class Installer
    RECOMMENDATION = 'export PATH="$HOME/.local/bin:$PATH"'

    def self.call(**options)
      new(**options).call
    end

    def initialize(executable_path:, home: ENV.fetch("HOME"), env: ENV, dry_run: false, force: false, on_event: nil)
      @executable_path = File.expand_path(executable_path)
      @home = File.expand_path(home)
      @env = env
      @dry_run = dry_run
      @force = force
      @on_event = on_event
    end

    def call
      emit("progress", "install.validate_target", "running", "Checking project executable")
      target = source_target
      link = File.join(@home, ".local", "bin", "vdd")
      result = base_result(link: link, target: target)

      unless target == expected_target_path
        emit("error", "install.validate_target", "error", target,
             cause: target, next_action: "Fix the project executable and retry")
        return result.merge(status: "error", phase: "validation", errors: [target],
                            next_action: "Fix the project executable and retry",
                            exit_code: EXIT_VALIDATION)
      end
      emit("success", "install.validate_target", "success", "Project executable valid")

      emit("progress", "install.check_link", "running", "Checking user link")
      if same_target?(link, target)
        emit("success", "install.check_link", "success", "VDD already installed", link: link)
        return report_path(result.merge(status: "already_installed", phase: "complete"))
      end
      if destination_conflicts?(link, target)
        conflict = conflict_result(link, target)
        emit("error", "install.check_link", "error", "Installation target is occupied",
             cause: conflict[:errors].first, impact: "The existing file was not changed",
             next_action: conflict[:next_action])
        return conflict
      end
      emit("success", "install.check_link", "success", "Installation target available", link: link)

      if @dry_run
        emit("warning", "install.create_link", "warning", "Dry run complete; no link created")
        return report_path(result.merge(status: "dry-run", phase: "planned"))
      end

      emit("progress", "install.create_link", "running", "Creating user link")
      create_link(link, target)
      emit("success", "install.create_link", "success", "User link created", link: link)
      report_path(result.merge(status: "installed", phase: "complete"))
    rescue SystemCallError => error
      emit("error", "install.create_link", "error", "Could not create user link",
           cause: error.message, next_action: "Check directory permissions and retry")
      base_result(link: link, target: target).merge(status: "error", phase: "installation",
                                                    errors: ["Could not install vdd: #{error.message}"],
                                                    next_action: "Check directory permissions and retry",
                                                    exit_code: EXIT_VALIDATION)
    end

    private

    def source_target
      target = File.realpath(@executable_path)
      expected_target = expected_target_path
      return "VDD executable not found: #{expected_target}" unless File.file?(target)
      return "VDD executable is not executable: #{target}" unless File.executable?(target)
      return "VDD executable must belong to this project: #{target}" unless target == expected_target

      target
    rescue Errno::ENOENT, Errno::EACCES
      "VDD executable not found: #{@executable_path}"
    end

    def expected_target_path
      File.join(File.expand_path("../..", __dir__), "bin", "vdd")
    end

    def base_result(link:, target:)
      path_configured = path_configured?
      {
        command: "install",
        issue: nil,
        status: "pending",
        phase: nil,
        repositories: { backend: nil, frontend: nil },
        log_file: nil,
        errors: [],
        link: link,
        target: target,
        path_configured: path_configured,
        recommendation: path_configured ? nil : RECOMMENDATION,
        exit_code: EXIT_SUCCESS
      }
    end

    def report_path(result)
      if result[:path_configured]
        emit("success", "install.check_path", "success", "User directory is on PATH")
      else
        emit("warning", "install.check_path", "warning", "User directory is not on PATH",
             next_action: result[:recommendation])
      end
      result
    end

    def emit(event, action, status, message, details = {}, **keyword_details)
      details = details.merge(keyword_details)
      @on_event&.call(event: event, action: action, status: status, message: message, details: details)
    end

    def path_configured?
      paths = @env.fetch("PATH", "").split(File::PATH_SEPARATOR)
      paths.any? { |path| File.expand_path(path) == File.join(@home, ".local", "bin") }
    end

    def destination_conflicts?(link, target)
      return false unless File.exist?(link) || File.symlink?(link)
      return false if File.symlink?(link) && same_target?(link, target)
      return false if @force && File.symlink?(link)

      true
    end

    def same_target?(link, target)
      File.realpath(link) == target
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def conflict_result(link, target)
      next_action = 'Remove the file manually or use --force only for a conflicting symlink.'
      base_result(link: link, target: target).merge(
        status: "error",
        phase: "validation",
        errors: ["Installation conflict: #{link} already exists and does not point to #{target}. " \
                 "Remove it manually or retry with --force for a conflicting symlink."],
        impact: "The existing file was not changed",
        next_action: next_action,
        exit_code: EXIT_VALIDATION
      )
    end

    def create_link(link, target)
      directory = File.dirname(link)
      created_directory = !Dir.exist?(directory)
      FileUtils.mkdir_p(directory, mode: 0o700) if created_directory
      File.chmod(0o700, directory) if created_directory
      File.unlink(link) if @force && File.symlink?(link)
      File.symlink(target, link)
    end
  end
end
