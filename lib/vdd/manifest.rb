# frozen_string_literal: true

require "pathname"

module Vdd
  module Manifest
    REQUIRED_KEYS = %w[
      ISSUE_ID ISSUE_NUMBER ISSUE_TYPE ISSUE_BRANCH
      WORKSPACE_WORKTREE_PATH CRM_WORKTREE_PATH AIO_WORKTREE_PATH
    ].freeze

    ALLOWED_KEYS = %w[
      ISSUE_ID ISSUE_NUMBER ISSUE_TYPE ISSUE_BRANCH
      WORKSPACE_REPO_ID WORKSPACE_WORKTREE_PATH WORKSPACE_ORCA_ID WORKSPACE_BRANCH
      CRM_SOURCE_PATH CRM_WORKTREE_PATH CRM_BRANCH
      AIO_SOURCE_PATH AIO_WORKTREE_PATH AIO_BRANCH
    ].freeze

    PATH_KEYS = %w[
      WORKSPACE_WORKTREE_PATH CRM_SOURCE_PATH CRM_WORKTREE_PATH AIO_SOURCE_PATH AIO_WORKTREE_PATH
    ].freeze

    module_function

    def load(path)
      manifest_path = Pathname.new(path).expand_path
      raise ContextError, "Manifest does not exist: #{manifest_path}" unless manifest_path.file?
      raise ContextError, "Manifest must not be a symlink: #{manifest_path}" if manifest_path.symlink?

      values = {}
      manifest_path.each_line.with_index(1) do |raw_line, line_number|
        line = raw_line.chomp
        next if line.empty? || line.lstrip.start_with?("#")

        key, value = line.split("=", 2)
        unless key&.match?(/\A[A-Z][A-Z0-9_]*\z/) && value
          raise ContextError, "Invalid manifest line #{line_number}: #{manifest_path}"
        end
        unless ALLOWED_KEYS.include?(key)
          raise ContextError, "Unsupported manifest key #{key}: #{manifest_path}"
        end
        if values.key?(key)
          raise ContextError, "Duplicate manifest key #{key}: #{manifest_path}"
        end
        if value.include?("\0") || value.include?("\r") || value.include?("\n")
          raise ContextError, "Unsafe manifest value for #{key}: #{manifest_path}"
        end
        if PATH_KEYS.include?(key) && !value.start_with?("/")
          raise ContextError, "Manifest path must be absolute for #{key}: #{manifest_path}"
        end

        values[key] = value
      end

      missing = REQUIRED_KEYS.reject { |key| values.key?(key) && !values[key].empty? }
      unless missing.empty?
        raise ContextError, "Manifest is incomplete (missing #{missing.join(", ")}): #{manifest_path}"
      end

      values
    rescue Errno::ENOENT => error
      raise ContextError, "Manifest does not exist: #{manifest_path}: #{error.message}"
    rescue Errno::EACCES => error
      raise ContextError, "Could not read manifest #{manifest_path}: #{error.message}"
    end
  end
end
