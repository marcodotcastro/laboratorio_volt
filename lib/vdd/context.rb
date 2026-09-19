# frozen_string_literal: true

require "pathname"

module Vdd
  Context = Data.define(:issue_id, :issue_number, :issue_type, :issue_branch,
                        :manifest_path, :workspace_path, :backend_path,
                        :frontend_path) do
    ISSUE_TYPES = {
      "b" => "bug", "bug" => "bug",
      "f" => "feature", "feature" => "feature",
      "i" => "improvement", "improvement" => "improvement"
    }.freeze

    def self.resolve(issue: nil, cwd: Dir.pwd, env: ENV, allow_missing: false, allow_issue_override: false)
      root = Pathname.new(cwd).expand_path
      context = load_context(root, env)
      state_dir = Pathname.new(env["WORKSPACE_STATE_DIR"] || context["WORKSPACE_STATE_DIR"] || root.join(".workspace")).expand_path
      requested_issue = normalize_issue(issue) if issue
      environment_issue = normalize_issue(env["WORKSPACE_ISSUE_ID"]) if env["WORKSPACE_ISSUE_ID"]
      context_issue = normalize_issue(context["WORKSPACE_ISSUE_ID"]) if context["WORKSPACE_ISSUE_ID"]
      pointer_issue = normalize_issue(read_first_line(state_dir.join("current_issue"))) if state_dir.join("current_issue").file?
      manifest_issue = manifest_issue_for(root, state_dir)

      workspace_issues = [context_issue, manifest_issue].compact.uniq
      if workspace_issues.length > 1 && !allow_issue_override
        raise ContextError, "Conflicting Workspace issue context: #{workspace_issues.join(", ")}; keep one context source"
      end

      workspace_issue = workspace_issues.first
      fallback_issues = [environment_issue, pointer_issue].compact.uniq
      local_issues = workspace_issue ? [workspace_issue] : fallback_issues
      if local_issues.length > 1 && !allow_issue_override
        raise ContextError, "Conflicting local issue context: #{local_issues.join(", ")}; keep one context source"
      end
      if requested_issue && local_issues.any? && requested_issue != local_issues.first && !allow_issue_override
        raise ContextError, "Issue #{requested_issue} conflicts with local context #{local_issues.first}; use the matching --issue or change context"
      end

      issue_id = requested_issue || local_issues.first
      return nil if issue_id.nil? && allow_missing
      raise ContextError, "No issue context found; use --issue NUM or run vdd issue create NUM" unless issue_id

      manifest_path = state_dir.join("issues", "#{issue_id}.env")
      values = manifest_path.file? ? Manifest.load(manifest_path) : {}
      manifest_issue = values["ISSUE_ID"] && normalize_issue(values["ISSUE_ID"])
      raise ContextError, "Manifest issue does not match requested issue: #{manifest_path}" if manifest_issue && manifest_issue != issue_id

      number = values["ISSUE_NUMBER"] || issue_id.delete_prefix("CC-")
      type = normalize_type(values["ISSUE_TYPE"] || "improvement")
      branch = values["ISSUE_BRANCH"] || default_branch(number, type)
      new(issue_id: issue_id, issue_number: Integer(number, 10), issue_type: type,
          issue_branch: branch, manifest_path: manifest_path.to_s,
          workspace_path: values["WORKSPACE_WORKTREE_PATH"],
          backend_path: values["CRM_WORKTREE_PATH"], frontend_path: values["AIO_WORKTREE_PATH"])
    rescue ArgumentError
      raise ContextError, "Issue number must be a positive integer"
    end

    def self.state_dir(cwd: Dir.pwd, env: ENV)
      root = Pathname.new(cwd).expand_path
      context = load_context(root, env)
      Pathname.new(env["WORKSPACE_STATE_DIR"] || context["WORKSPACE_STATE_DIR"] || root.join(".workspace")).expand_path.to_s
    end

    def workspace_available?
      File.file?(manifest_path)
    end

    def self.normalize_issue(value)
      text = value.to_s.strip.upcase
      number = text.delete_prefix("CC-")
      raise ContextError, "Issue number must be a positive integer" unless number.match?(/\A[1-9]\d*\z/)

      "CC-#{Integer(number, 10)}"
    end

    def self.normalize_type(value)
      type = ISSUE_TYPES[value.to_s.downcase]
      raise ContextError, "Invalid issue type #{value.inspect}; use bug, feature or improvement" unless type

      type
    end

    def self.load_context(root, env)
      configured = env["WORKSPACE_CONTEXT_FILE"]
      if configured
        configured_path = Pathname.new(configured)
        raise ContextError, "Workspace context file must be absolute: #{configured}" unless configured_path.absolute?
        raise ContextError, "Workspace context file does not exist: #{configured}" unless configured_path.file?
        raise ContextError, "Workspace context file must not be a symlink: #{configured}" if configured_path.symlink?
      end
      paths = [configured && Pathname.new(configured).expand_path, *context_paths(root)].compact
      context_path = paths.find(&:file?)
      return {} unless context_path
      raise ContextError, "Workspace context file must not be a symlink: #{context_path}" if context_path.symlink?

      values = {}
      context_path.each_line.with_index(1) do |raw_line, line_number|
        line = raw_line.chomp
        next if line.empty? || line.lstrip.start_with?("#")
        key, value = line.split("=", 2)
        unless %w[WORKSPACE_STATE_DIR WORKSPACE_ISSUE_ID WORKSPACE_CONFIG_FILE].include?(key) && value
          raise ContextError, "Invalid context line #{line_number}: #{context_path}"
        end
        raise ContextError, "Duplicate context key #{key}: #{context_path}" if values.key?(key)
        raise ContextError, "Context value is empty: #{key}" if value.empty?
        if key != "WORKSPACE_ISSUE_ID" && !value.start_with?("/")
          raise ContextError, "Context path must be absolute for #{key}: #{context_path}"
        end
        values[key] = value
      end
      required = %w[WORKSPACE_STATE_DIR WORKSPACE_ISSUE_ID WORKSPACE_CONFIG_FILE]
      missing = required.reject { |key| values.key?(key) }
      raise ContextError, "Workspace context is incomplete (missing #{missing.join(", ")}): #{context_path}" unless missing.empty?
      values
    end

    def self.context_paths(root)
      paths = []
      current = root
      loop do
        paths << current.join(".workspace", "context.env")
        parent = current.parent
        break if parent == current

        current = parent
      end
      paths
    end

    def self.manifest_issue_for(root, state_dir)
      candidates = state_dir.join("issues").glob("CC-*.env").filter_map do |path|
        workspace_value = manifest_value(path, "WORKSPACE_WORKTREE_PATH")
        next unless workspace_value

        workspace = Pathname.new(workspace_value).expand_path
        next unless workspace == root || root.to_s.start_with?("#{workspace}/")

        values = Manifest.load(path)
        normalize_issue(values["ISSUE_ID"])
      end
      return nil if candidates.empty?
      raise ContextError, "Multiple issue manifests match #{root}" unless candidates.uniq.one?

      candidates.first
    end

    def self.manifest_value(path, key)
      path.each_line do |raw_line|
        line = raw_line.chomp
        next if line.empty? || line.lstrip.start_with?("#")

        candidate_key, value = line.split("=", 2)
        return value if candidate_key == key && value
      end
      nil
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def self.read_first_line(path)
      path.each_line.first&.strip
    end

    def self.default_branch(number, type)
      prefix = type == "bug" ? "fix" : "feat"
      "#{prefix}/cc#{number}-#{type}"
    end

    private_class_method :load_context, :context_paths, :manifest_issue_for,
                         :manifest_value, :read_first_line, :default_branch
  end
end
