# frozen_string_literal: true

module Vdd
  EXIT_SUCCESS = 0
  EXIT_USAGE = 2
  EXIT_CONTEXT = 3
  EXIT_VALIDATION = 4
  EXIT_DEPENDENCY = 5
  EXIT_PRODUCT = 6
  EXIT_EXTERNAL = 7

  class Error < StandardError
    attr_reader :code

    def initialize(message, code: EXIT_VALIDATION)
      @code = code
      super(message)
    end
  end

  class UsageError < Error
    def initialize(message)
      super(message, code: EXIT_USAGE)
    end
  end

  class ContextError < Error
    def initialize(message)
      super(message, code: EXIT_CONTEXT)
    end
  end
end
