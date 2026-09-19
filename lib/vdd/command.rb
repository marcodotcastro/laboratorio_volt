# frozen_string_literal: true

module Vdd
  Command = Data.define(:name, :arguments, :options) do
    def dry_run?
      options.fetch(:dry_run, false)
    end

    def display_name
      name.tr("_", " ")
    end
  end
end
