# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tempfile"

module Vdd
  module AI
    module ProviderConfig
      CONFIG_DIR = "vdd"
      CONFIG_FILE = "config.yml"

      module_function

      def load(home: ENV.fetch("HOME"), env: ENV)
        path = path(home: home, env: env)
        return nil unless path.file?
        raise Error, "AI provider config must not be a symlink: #{path}" if path.symlink?

        provider = nil
        path.each_line.with_index(1) do |raw_line, line_number|
          line = raw_line.chomp
          next if line.empty? || line.lstrip.start_with?("#")

          key, value = line.split(":", 2)
          unless key == "provider" && value
            raise Error, "Invalid AI provider config line #{line_number}: #{path}"
          end
          raise Error, "Duplicate AI provider config key: provider" if provider

          provider = Provider.normalize(value.strip)
        end
        provider
      rescue Errno::EACCES => error
        raise Error, "Could not read AI provider config #{path}: #{error.message}"
      end

      def save(provider, home: ENV.fetch("HOME"), env: ENV)
        normalized = Provider.normalize(provider)
        config_path = path(home: home, env: env)
        FileUtils.mkdir_p(config_path.dirname, mode: 0o700)
        File.chmod(0o700, config_path.dirname)

        temporary = Tempfile.new(".config-", config_path.dirname.to_s)
        temporary.chmod(0o600)
        temporary.write("provider: #{normalized}\n")
        temporary.close
        FileUtils.mv(temporary.path, config_path.to_s)
        File.chmod(0o600, config_path)
        normalized
      ensure
        temporary&.close!
      end

      def path(home: ENV.fetch("HOME"), env: ENV)
        config_home = env["XDG_CONFIG_HOME"] || Pathname.new(home).join(".config").to_s
        Pathname.new(config_home).expand_path.join(CONFIG_DIR, CONFIG_FILE)
      end
      private_class_method :path
    end
  end
end
