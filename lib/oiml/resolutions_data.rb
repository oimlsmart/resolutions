# frozen_string_literal: true

module Oiml
  module ResolutionsData
    autoload :AgendaBuilder,            "oiml/resolutions_data/agenda_builder"
    autoload :BodyType,                 "oiml/resolutions_data/body_type"
    autoload :DecisionCollectionBuilder, "oiml/resolutions_data/decision_collection_builder"
    autoload :IdentifierParser,         "oiml/resolutions_data/identifier_parser"
    autoload :MinutesBuilder,           "oiml/resolutions_data/minutes_builder"
    autoload :Ordinal,                  "oiml/resolutions_data/ordinal"
    autoload :Version,                  "oiml/resolutions_data/version"

    module Ocr
      autoload :MarkdownReader, "oiml/resolutions_data/ocr/markdown_reader"
    end

    module Pdf
      autoload :TextExtractor,  "oiml/resolutions_data/pdf/text_extractor"
    end
  end
end
