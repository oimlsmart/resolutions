# frozen_string_literal: true

require "spec_helper"

module Oiml
  module ResolutionsData
    RSpec.describe Ordinal do
      describe ".suffix" do
        it "suffixes 1st, 2nd, 3rd" do
          expect(described_class.suffix(1)).to eq("st")
          expect(described_class.suffix(2)).to eq("nd")
          expect(described_class.suffix(3)).to eq("rd")
        end

        it "suffixes the teens as th" do
          expect(described_class.suffix(11)).to eq("th")
          expect(described_class.suffix(12)).to eq("th")
          expect(described_class.suffix(13)).to eq("th")
        end

        it "suffixes the rest of the cycle" do
          expect(described_class.suffix(4)).to eq("th")
          expect(described_class.suffix(9)).to eq("th")
          expect(described_class.suffix(21)).to eq("st")
          expect(described_class.suffix(33)).to eq("rd")
          expect(described_class.suffix(52)).to eq("nd")
          expect(described_class.suffix(60)).to eq("th")
        end
      end
    end
  end
end
