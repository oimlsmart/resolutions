#!/usr/bin/env ruby
# frozen_string_literal: true

# Driver: walk every PDF under reference-docs/{ciml,conferences}/ (recursive)
# and OCR it. For each PDF, write the concatenated markdown to
# reference-docs/.ocr/md/<slug>.md. Chunks are cached by SHA-256 of
# (input, start, end) — re-runs resume for free.

require_relative "glm_ocr"
require "open3"
require "fileutils"
require "yaml"

module ResolutionsData
  module OcrRun
    ROOT   = File.expand_path("../../", __dir__)
    PDFS   = Dir.glob(File.join(ROOT, "reference-docs", "{ciml,conferences}", "**", "*.pdf")).sort
    MD_DIR = File.join(ROOT, "reference-docs", ".ocr", "md")
    ONLY   = ENV["ONLY"] # set ONLY=<slug> to process one PDF

    def self.page_count(pdf)
      out, _, st = Open3.capture3("pdfinfo", pdf)
      return $1.to_i if out =~ /^Pages:\s+(\d+)/
      out, = Open3.capture3("mdls", "-name", "kMDItemNumberOfPages", pdf)
      return $1.to_i if out =~ /=\s+(\d+)/
      raise "cannot determine page count for #{pdf}"
    end

    def self.run
      FileUtils.mkdir_p(MD_DIR)
      targets = ONLY && !ONLY.empty? ? PDFS.select { |p| File.basename(p, ".pdf") == ONLY } : PDFS
      raise "no matching PDF for ONLY=#{ONLY}" if targets.empty?

      stats = Hash.new(0)
      targets.each do |pdf|
        slug  = File.basename(pdf, ".pdf")
        pages = page_count(pdf)
        t0    = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        md    = ResolutionsData::GlmOcr.new.ocr_pdf(pdf, num_pages: pages)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        File.write(File.join(MD_DIR, "#{slug}.md"), md)
        stats[:pages]  += pages
        stats[:chars]  += md.size
        stats[:pdfs]   += 1
        puts "  ok   #{slug}  (#{pages}p, #{md.size} chars, #{format('%4.1f', elapsed)}s)"
      rescue => e
        stats[:error] += 1
        warn "  FAIL #{slug}: #{e.class}: #{e.message}"
      end

      puts
      puts "Summary: #{stats[:pdfs]} PDFs OCR'd, #{stats[:pages]} pages, #{stats[:chars]} chars, #{stats[:error]} errors"
      exit 1 if stats[:error] > 0
    end
  end
end

ResolutionsData::OcrRun.run if $PROGRAM_NAME == __FILE__
