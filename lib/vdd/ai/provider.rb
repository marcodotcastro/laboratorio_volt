# frozen_string_literal: true

module Vdd
  module AI
    module Provider
      SUPPORTED = %w[codex claude antigravity gemini].freeze
      SENSITIVE_NAME = /(TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTHORIZATION|PRIVATE_KEY)/i

      module_function

      def valid?(value)
        SUPPORTED.include?(value.to_s.strip.downcase)
      end

      def normalize(value)
        provider = value.to_s.strip.downcase
        return provider if SUPPORTED.include?(provider)

        raise UsageError, "Unsupported AI provider #{value.inspect}; use codex, claude, antigravity, or gemini"
      end

      def generate(provider, prompt:, runner: Runner, env: ENV, logger: nil, state_dir: nil, issue_id: nil)
        normalized = normalize(provider)
        sanitized_prompt = sanitize(prompt, env)
        body = case normalized
        when "codex"
          Codex.call(prompt: sanitized_prompt, runner: runner, env: env, logger: logger,
                     state_dir: state_dir, issue_id: issue_id)
        when "claude"
          Claude.call(prompt: sanitized_prompt, runner: runner, env: env, logger: logger)
        when "antigravity"
          Antigravity.call(prompt: sanitized_prompt, runner: runner, env: env, logger: logger)
        when "gemini"
          Gemini.call(prompt: sanitized_prompt, runner: runner, env: env, logger: logger)
        end
        sanitize(body, env).byteslice(0, 20_000).to_s.strip
      end

      def repair(provider, prompt:, root:, runner: Runner, env: ENV, logger: nil, state_dir: nil, issue_id: nil)
        normalized = normalize(provider)
        sanitized_prompt = sanitize(prompt, env)
        body = case normalized
        when "codex"
          Codex.repair(prompt: sanitized_prompt, root: root, runner: runner, env: env,
                       logger: logger, state_dir: state_dir, issue_id: issue_id)
        when "claude"
          Claude.repair(prompt: sanitized_prompt, root: root, runner: runner, env: env, logger: logger)
        when "antigravity"
          Antigravity.repair(prompt: sanitized_prompt, root: root, runner: runner, env: env, logger: logger)
        when "gemini"
          Gemini.repair(prompt: sanitized_prompt, root: root, runner: runner, env: env, logger: logger)
        end
        sanitize(body, env).byteslice(0, 20_000).to_s.strip
      end

      def sanitize(value, env)
        text = value.to_s.dup
        env.to_h.each do |name, secret|
          next unless name.to_s.match?(SENSITIVE_NAME) && !secret.to_s.empty?

          text.gsub!(secret.to_s, "[REDACTED]")
        end
        text
      end
    end
  end
end
