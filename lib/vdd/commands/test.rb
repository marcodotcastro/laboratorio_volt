# frozen_string_literal: true

module Vdd
  module Commands
    module Test
      module_function

      def call(context:, selection: :all, state_dir:, runner: Runner, env: ENV, on_event: nil)
        ProductTest.run_suite(context: context, selection: selection, state_dir: state_dir,
                              runner: runner, env: env, on_event: on_event)
      end

      def render(payload)
        ProductTest.render(payload)
      end
    end
  end
end
