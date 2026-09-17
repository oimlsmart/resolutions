# frozen_string_literal: true

require "spec_helper"
require "yaml"

RSpec.describe "meeting titles" do
  root = File.expand_path("../../..", __dir__)
  meetings = Dir[File.join(root, "edoxen-data", "meetings", "*.yaml")]

  it "exist" do
    expect(meetings).not_to be_empty
  end

  it "carry correctly suffixed ordinals" do
    bad = []

    meetings.each do |path|
      text = File.read(path, encoding: "UTF-8")
      text.scan(/\b(\d+)(st|nd|rd|th)\b/) do |number, suffix|
        expected = Oiml::ResolutionsData::Ordinal.suffix(Integer(number, 10))
        bad << "#{File.basename(path)}: #{number}#{suffix} (expected #{number}#{expected})" if suffix != expected
      end
    end

    expect(bad).to eq([])
  end
end
