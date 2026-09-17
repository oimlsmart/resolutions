# frozen_string_literal: true

module Oiml
  module ResolutionsData
    # English ordinal suffixes for meeting numbers (1st, 2nd, 3rd, 11th…).
    module Ordinal
      def self.suffix(number)
        ones = number % 10
        tens = (number % 100) / 10
        return "th" if tens == 1

        case ones
        when 1 then "st"
        when 2 then "nd"
        when 3 then "rd"
        else "th"
        end
      end
    end
  end
end
