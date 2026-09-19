# frozen_string_literal: true

require "pathname"

module Vdd
  module Checks
    module Workspace
      module_function

      def call(context:, root: Dir.pwd)
        paths = {
          workspace: context&.workspace_path || root,
          backend: context&.backend_path,
          frontend: context&.frontend_path
        }
        paths.filter_map do |name, path|
          next unless path

          path = Pathname.new(path)
          if path.directory?
            { name: name.to_s, status: "ok", message: "#{name} worktree available", path: path.to_s }
          else
            { name: name.to_s, status: "error", message: "#{name} worktree does not exist: #{path}",
              recommendation: "create the #{name} worktree before running doctor", path: path.to_s }
          end
        end
      end
    end
  end
end
