# frozen_string_literal: true

module MICharismaSeeders
  class Error < StandardError
    attr_reader :location

    def initialize(message, location: nil)
      @location = location
      super(location ? "#{location}: #{message}" : message)
    end
  end

  class ParseError < Error; end
  class ValidationError < Error; end
  class DuplicateKeyError < ValidationError; end
  class UnknownSequenceError < ValidationError; end
  class CodeError < ValidationError; end
  class AmbiguousCodeError < CodeError; end
end
