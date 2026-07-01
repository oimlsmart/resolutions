#!/usr/bin/env ruby
# frozen_string_literal: true

# Parse OIML resolution OCR markdown into Edoxen YAML.
#
# Handles three OCR shapes (see TODO.work/07-author-plan.md):
#   A. Modern:    "## Resolution Conference/YYYY/NN"   (CIML 44+, Conf 14+)
#   B. Older:     "## Resolution no.N"                 (CIML 43, Conf 13)
#   C. Decisions: "## N <section title>"               (CIML 39–42) — DEFERRED
#
# Bilingual PDFs (CIML 43, Conf 13) are split at the "# Résolutions" header
# into EN + FR halves; each half is parsed and emitted as a separate YAML.

require "yaml"
require "fileutils"
require "digest"

module ResolutionsData
  module Author
    ROOT       = File.expand_path("..", __dir__)
    OCR_DIR    = File.join(ROOT, "reference-docs", ".ocr", "md")
    OUT_DIR    = File.join(ROOT, "resolutions")
    MANIFEST   = File.join(ROOT, "scripts", "manifest.yaml")
    PENDING    = File.join(OUT_DIR, "_pending_review.txt")

    SCHEMA_URL = "https://raw.githubusercontent.com/metanorma/edoxen/refs/heads/main/schema/edoxen.yaml"

    # (verb-prefix, edoxen-type). Order matters — longer prefixes first.
    CONSIDERATION_PREFIXES = [
      ["Following the recommendation", "following_recommendation"],
      ["Having regard to",   "having_regard_to"],
      ["Having regard",      "having_regard"],
      ["Noting that",        "noting"],
      ["Noting",             "noting"],
      ["Recalling",          "recalling"],
      ["Considering that",   "considering"],
      ["Considering",        "considering"],
    ].freeze

    ACTION_PREFIXES = [
      ["Gives its definitive discharge", "gives_discharge"],
      ["Gives discharge",                "gives_discharge"],
      ["Re-affirms",                     "reaffirms"],
      ["Reaffirms",                      "reaffirms"],
      ["Resolves that",                  "resolves"],
      ["Resolves:",                      "resolves"],
      ["Resolves",                       "resolves"],
      ["Approves",                       "approves"],
      ["Elects",                         "elects"],
      ["Endorses",                       "endorses"],
      ["Thanks",                         "thanks"],
      ["Instructs",                      "instructs"],
      ["Requests",                       "requests"],
      ["Decides",                        "decides"],
      ["Charges",                        "charges"],
      ["Supports",                       "supports"],
      ["Rescinds",                       "rescinds"],
      ["Acknowledges",                   "acknowledges"],
      ["Notes",                        "notes"],
      ["Takes note",                   "notes"],
      ["Welcomes",                     "welcomes"],
      ["Renews",                       "renews"],
      # Past-tense forms used in older formal resolutions (CIML 43-48, ~2008-2013)
      ["Approved",                     "approves"],
      ["Elected",                      "elects"],
      ["Endorsed",                     "endorses"],
      ["Resolved",                     "resolves"],
      ["Thanked",                      "thanks"],
      ["Instructed",                   "instructs"],
      ["Requested",                    "requests"],
      ["Decided",                      "decides"],
      ["Charged",                      "charges"],
      ["Supported",                    "supports"],
      ["Rescinded",                    "rescinds"],
      ["Acknowledged",                 "acknowledges"],
      ["Noted",                        "notes"],
      ["Welcomed",                     "welcomes"],
      ["Renewed",                      "renews"],
      # Imperative / additional verbs
      ["Appoints",                     "appoints"],
      ["Establishes",                  "establishes"],
      ["Proclaims",                    "proclaims"],
      ["Confirms",                     "confirms"],
      ["Instructs the Bureau to",      "instructs"],
      ["Instructs its President",      "instructs"],
      ["Instructs the Bureau",         "instructs"],
      ["Following the recommendation", "following_recommendation"],
    ].freeze

    # French equivalents
    FR_CONSIDERATION_PREFIXES = [
      ["Vu",               "having_regard_to"],
      ["Attendu",          "having_regard_to"],
      ["Notant",           "noting"],
      ["Prenant note",     "noting"],
      ["Rappelant",        "recalling"],
      ["Considérant",      "considering"],
    ].freeze

    FR_ACTION_PREFIXES = [
      ["Approuve",     "approves"],
      ["Élit",         "elects"],
      ["Elit",         "elects"],
      ["Soutient",     "endorses"],
      ["Décide que",   "decides"],
      ["Décide",       "decides"],
      ["Charge",       "charges"],
      ["Demande",      "requests"],
      ["Remercie",     "thanks"],
      ["Résout",       "resolves"],
      ["Resout",       "resolves"],
      ["Notes",        "notes"],
      ["Prend note",   "notes"],
      ["Accueille",    "welcomes"],
      # French past-tense forms (used in CIML 44+ FR formal resolutions)
      ["a approuvé",                  "approves"],
      ["a adopté",                    "approves"],
      ["a donné son accord",          "approves"],
      ["a approuvé le principe",      "approves"],
      ["a élu",                       "elects"],
      ["a soutenu",                   "endorses"],
      ["a décidé",                    "decides"],
      ["a chargé",                    "instructs"],
      ["a donné instruction",         "instructs"],
      ["a instruit",                  "instructs"],
      ["a demandé",                   "requests"],
      ["a prié",                      "requests"],
      ["a remercié",                  "thanks"],
      ["a exprimé son appréciation",  "thanks"],
      ["a exprimé",                   "notes"],
      ["a noté",                      "notes"],
      ["a pris note",                 "notes"],
      ["a noté que",                  "notes"],
      ["a accueilli",                 "welcomes"],
      ["a renouvelé",                 "renews"],
      ["a nommé",                     "appoints"],
      ["a établi",                    "establishes"],
      ["a confirmé",                  "confirms"],
      ["a rescindé",                  "rescinds"],
      ["a souhaité",                  "wishes"],
      ["a fixé",                      "sets"],
    ].freeze

    # Extra EN verbs seen in CIML minutes-style resolutions
    EXTRA_EN_ACTION_PREFIXES = [
      ["Notes",         "notes"],
      ["Takes note",    "notes"],
      ["Welcomes",      "welcomes"],
      ["Instructs",     "instructs"],  # also captured above; first match wins
      ["Renews",        "renews"],
      ["Endorses",      "endorses"],   # duplicate to be safe
    ].freeze

    # Group manifest entries by meeting identity. A CIML meeting is keyed
    # by "ciml-{N}"; a Conference by "conference-{S}". The English and
    # French source PDFs of the same meeting collapse into a single emit
    # pass, producing ONE per-meeting YAML file with embedded
    # Localizable resolution rows.
    def self.group_sources_by_meeting(sources)
      groups = {}
      sources.each do |src|
        next unless src["slug"]
        # Strip the trailing language tag (en / fr / bilingual, case-insensitive)
        # so the same meeting with EN and FR PDFs groups together.
        base_slug = src["slug"].sub(/-(en|fr|bilingual)\z/i, '')
        groups[base_slug] ||= []
        groups[base_slug] << src
      end
      groups
    end

    def self.run
      FileUtils.mkdir_p(OUT_DIR)
      only = ENV["ONLY"] # set ONLY=<base_slug> to author one meeting
      sources = YAML.load_file(MANIFEST)["sources"]
      by_meeting = group_sources_by_meeting(sources)
      by_meeting = by_meeting.select { |slug, _| slug == only } if only && !only.empty?
      raise "no meeting matching ONLY=#{only}" if by_meeting.empty?

      stats = Hash.new(0)
      pending = []

      # Group source PDFs by meeting identity (kind + number). Each
      # meeting gets ONE YAML file containing every language version
      # (each resolution row tagged with its `language:`). See
      # TODO.complete/13-meeting-single-file-yaml.md.
      by_meeting.each do |meeting_slug, meeting_sources|
        emit_meeting(meeting_slug, meeting_sources, stats, pending)
      end

      File.write(PENDING, pending.join("\n")) unless pending.empty?

      puts
      puts "Summary:"
      puts "  YAML files emitted:    #{stats[:emitted]}"
      puts "  Resolutions parsed:    #{stats[:resolutions]}"
      puts "  Decisions deferred:    #{stats[:deferred]}  (CIML 39–42 narrative style)"
      puts "  Pending-review notes:  #{pending.size}  → #{PENDING}"
      exit 1 if stats[:error] > 0
    end

    def self.emit_meeting(meeting_slug, meeting_sources, stats, pending)
      # Parsed resolutions, grouped by canonical identifier. Each value
      # is a hash of language_code -> parsed-resolution-hash so we can
      # merge EN + FR into a single Resolution with multiple
      # localizations.
      by_identifier = {}
      titles_by_lang = {}
      meeting_sources.each do |src|
        md_slug = src["slug"]
        md_path = File.join(OCR_DIR, "#{md_slug}.md")
        unless File.exist?(md_path)
          pending << "#{meeting_slug}: missing OCR markdown for #{md_slug}"
          next
        end
        md = File.read(md_path)

        # For bilingual sources, split into EN + FR halves and tag each
        # parsed resolution with its actual language. Non-bilingual
        # sources get a single tag based on src['lang'].
        tagged =
          case src["lang"]
          when "bilingual"
            en_md, fr_md = split_bilingual(md)
            [
              *parse_with_fallback(en_md, src, :en).map { |r| [r, "eng"] },
              *parse_with_fallback(fr_md, src, :fr).map { |r| [r, "fra"] },
            ]
          when "fr"
            parse_with_fallback(md, src, :fr).map { |r| [r, "fra"] }
          else
            parse_with_fallback(md, src, :en).map { |r| [r, "eng"] }
          end

        tagged.each do |(r, lang_639_3)|
          r["language_code"] = lang_639_3
          r["script"] = "Latn"
          id_key = r["identifier"].to_s
          (by_identifier[id_key] ||= {})[lang_639_3] = r
        end
        stats[:resolutions] += tagged.size
        # For bilingual sources both halves share the same manifest title;
        # we put it in both eng and fra slots. The migrate script (and the
        # title_localized block in render) handles the duplication.
        case src["lang"]
        when "bilingual"
          titles_by_lang[:eng] ||= src["title"].to_s
          titles_by_lang[:fra] ||= src["title_fr"].to_s if src["title_fr"]
        when "fr"
          titles_by_lang[:fra] ||= src["title"].to_s
        else
          titles_by_lang[:eng] ||= src["title"].to_s
        end
      end

      resolutions = by_identifier.values.map { |langs| build_resolution_with_localizations(langs) }
      if resolutions.empty?
        pending << "#{meeting_slug}: parser found 0 resolutions (deferred)"
        return
      end

      stats[:emitted] += 1
      out_path = File.join(OUT_DIR, "#{meeting_slug}.yaml")
      File.write(out_path, render_meeting_collection(meeting_slug, meeting_sources, resolutions, titles_by_lang))
      puts "  ok   #{meeting_slug}  (#{resolutions.size} resolutions across #{meeting_sources.size} source PDF(s))"
    rescue => e
      stats[:error] += 1
      pending << "#{meeting_slug}: ERROR #{e.class}: #{e.message}"
    end

    # Build a single Resolution with one Localization per available
    # language. Language-agnostic fields (identifier, doi, urn,
    # agenda_item, dates) come from the English row when present,
    # otherwise from the first available language.
    def self.build_resolution_with_localizations(by_lang)
      primary = by_lang["eng"] || by_lang["fra"] || by_lang.values.first
      localizations = by_lang.values.map do |r|
        {
          "language_code" => r["language_code"],
          "script"        => r["script"] || "Latn",
          "title"         => r["title"],
          "subject"       => r["subject"],
          "considerations"=> r["considerations"] || [],
          "actions"       => r["actions"] || [],
          "approvals"     => r["approvals"] || [],
        }
      end
      {
        "identifier"    => primary["identifier"],
        "doi"           => primary["doi"],
        "urn"           => primary["urn"],
        "agenda_item"   => primary["agenda_item"],
        "dates"         => primary["dates"] || [],
        "localizations" => localizations,
      }
    end

    # Try the formal parser, then the narrative parser. The narrative
    # parser handles both formats:
    #   * CIML 39+ "## DECISIONS" + "## 1 Title"          (Arabic numerals)
    #   * CIML 15-29 "## MINUTES" + "## I — Title"        (Roman + sub-letter)
    def self.parse_with_fallback(md, src, lang)
      resolutions, _deferred = parse(md, src, lang)
      resolutions = parse_narrative(md, src, lang).first if resolutions.empty?
      resolutions
    end

    def self.render_meeting_collection(meeting_slug, meeting_sources, resolutions, titles_by_lang)
      primary     = meeting_sources.first
      kind        = primary["kind"]
      number      = primary["kind"] == "ciml" ? primary["meeting"] : primary["session"]
      body        = primary["kind"] == "ciml" ? "CIML Meeting" : "OIML Conference"
      urn_kind    = primary["kind"] == "ciml" ? "ciml" : "conference"

      en_default = "Resolutions of the #{number_to_ordinal(number, :en)} #{body} (#{primary['year']})"
      fr_default = "Résolutions #{number_to_ordinal(number, :fr)} #{body} (#{primary['year']})"
      canonical_title = titles_by_lang[:eng] || titles_by_lang[:fra] || en_default

      venue = primary["venue"]
      date_start = primary["date_start"] || "#{primary['year']}-01-01"
      date_end   = primary["date_end"]   || date_start
      dates_yaml = if date_start == date_end
        "  dates:\n  - start: '#{date_start}'\n    kind: meeting"
      else
        "  dates:\n  - start: '#{date_start}'\n    end: '#{date_end}'\n    kind: meeting"
      end

      pdf_paths = meeting_sources.map { |s| source_pdf_path(s) }.join(" | ")
      url_lines = meeting_sources.flat_map do |s|
        case s["lang"]
        when "bilingual"
          [
            "    - { ref: \"#{s['url'].to_s.gsub('"', '\"')}\", format: pdf, language_code: eng }",
            "    - { ref: \"#{s['url'].to_s.gsub('"', '\"')}\", format: pdf, language_code: fra }",
          ]
        when "fr"
          ["    - { ref: \"#{s['url'].to_s.gsub('"', '\"')}\", format: pdf, language_code: fra }"]
        else
          ["    - { ref: \"#{s['url'].to_s.gsub('"', '\"')}\", format: pdf, language_code: eng }"]
        end
      end.join("\n")

      available_langs = meeting_sources.flat_map do |s|
        case s["lang"]
        when "bilingual" then ["eng", "fra"]
        when "fr" then ["fra"]
        else ["eng"]
        end
      end.uniq.join(", ")

      <<~YAML
        # yaml-language-server: $schema=#{SCHEMA_URL}
        # Auto-generated by scripts/author_yaml.rb from #{pdf_paths}.
        # Meeting URN: urn:oiml:#{urn_kind}:meeting:#{meeting_slug}
        # Languages: #{available_langs}
        ---
        metadata:
          title: #{yaml_escape(canonical_title)}
          title_localized:
        #{localized_title_block(titles_by_lang)}
        #{dates_yaml}
          venue: #{yaml_escape(venue)}
          city: #{yaml_escape(primary['city'].to_s)}
          country_code: #{yaml_escape(primary['country_code'].to_s)}
          source_urls:
        #{url_lines}
        resolutions:
      YAML
        .concat(resolutions.map { |r| render_meeting_resolution(r) }.join("\n"))
    end

    def self.localized_title_block(titles_by_lang)
      rows = []
      rows << "    - { language_code: eng, script: Latn, title: #{yaml_escape(titles_by_lang[:eng].to_s)} }" if titles_by_lang[:eng]
      rows << "    - { language_code: fra, script: Latn, title: #{yaml_escape(titles_by_lang[:fra].to_s)} }" if titles_by_lang[:fra]
      rows.join("\n")
    end

    def self.render_meeting_resolution(r)
      indent = "  "
      lines = []
      lines << "#{indent}- identifier: #{yaml_escape(r['identifier'])}"
      lines << "#{indent}  doi: #{yaml_escape(r['doi'])}" if r["doi"]
      lines << "#{indent}  urn: #{yaml_escape(r['urn'])}" if r["urn"]
      lines << "#{indent}  agenda_item: '#{r['agenda_item']}'" if r["agenda_item"]
      if r["dates"] && r["dates"].any?
        lines << "#{indent}  dates:"
        r["dates"].each do |d|
          lines << "#{indent}  - start: '#{d['start']}'"
          lines << "#{indent}    kind: #{d['kind']}"
        end
      end
      lines << "#{indent}  localizations:"
      r["localizations"].each do |loc|
        lines << "#{indent}  - language_code: #{loc['language_code']}"
        lines << "#{indent}    script: #{loc['script']}"
        lines << "#{indent}    title: #{yaml_escape(loc['title'])}" if loc["title"]
        lines << "#{indent}    subject: #{yaml_escape(loc['subject'])}" if loc["subject"]
        if loc["considerations"] && loc["considerations"].any?
          lines << "#{indent}    considerations:"
          loc["considerations"].each { |c| lines << render_meeting_action_like(c, indent + "    ") }
        end
        if loc["actions"] && loc["actions"].any?
          lines << "#{indent}    actions:"
          loc["actions"].each { |a| lines << render_meeting_action_like(a, indent + "    ") }
        end
      end
      lines.join("\n")
    end

    def self.render_meeting_action_like(entry, indent)
      out = []
      out << "#{indent}- type: #{entry['type']}"
      msg = entry['message'].to_s
      out << "#{indent}  message: |"
      msg.to_s.split("\n").each do |line|
        out << "#{indent}    #{line}"
      end
      if entry['dates'] && entry['dates'].any?
        out << "#{indent}  dates:"
        entry['dates'].each do |d|
          out << "#{indent}  - start: '#{d['start']}'"
          out << "#{indent}    kind: #{d['kind']}"
        end
      end
      out.join("\n")
    end

    def self.emit_one(src, out_slug, md, lang, stats, pending)
      resolutions, deferred = parse(md, src, lang)

      # Fall back to narrative parser for CIML 39–42-style "DECISIONS" docs
      # (no formal "## Resolution" headers, but "## DECISIONS" + numbered sections).
      if resolutions.empty? && md =~ /#*\s*D[ÉE]CISIONS\b/i
        resolutions, deferred = parse_narrative(md, src, lang)
      end

      stats[:resolutions] += resolutions.size
      stats[:deferred]   += deferred
      stats[:emitted]    += 1 unless resolutions.empty?
      if resolutions.empty?
        pending << "#{out_slug}: parser found 0 resolutions (deferred)"
        return
      end
      out_path = File.join(OUT_DIR, "#{out_slug}.yaml")
      File.write(out_path, render_collection(src, out_slug, lang, resolutions))
      puts "  ok   #{out_slug}  (#{resolutions.size} resolutions)"
    rescue => e
      stats[:error] += 1
      warn "  FAIL #{out_slug}: #{e.class}: #{e.message}"
      pending << "#{out_slug}: ERROR #{e.class}: #{e.message}"
    end

    # Split a bilingual markdown doc at the FR half's resolutions header.
    # Returns [en_md, fr_md]. If no FR marker is found, returns [md, ""].
    #
    # Recognized split points (top-level `#` headers only):
    #   # Résolutions                         (most bilingual resolution docs)
    #   # DÉCISIONS et RÉSOLUTIONS            (ciml-38-decisions style)
    #   # Décisions et Résolutions            (variant capitalization)
    def self.split_bilingual(md)
      m = md.match(/\n#\s+(?:R[ée]solutions|D[ÉE]CISIONS\s+et\s+R[ÉE]SOLUTIONS|D[ée]cisions\s+et\s+R[ée]solutions)\b/)
      return [md, ""] unless m
      [md[0...m.begin(0)], md[m.begin(0)..]]
    end

    # Parse a single-language markdown stream into [resolutions, deferred_count].
    def self.parse(md, src, lang)
      res = []
      blocks = split_resolution_blocks(md)
      deferred = 0

      blocks.each do |(raw_header, body)|
        ident = parse_identifier(raw_header, src)
        if ident.nil?
          deferred += 1
          next
        end


        agenda_item = extract_agenda_item(body)
        subject_str = extract_subject(body, lang, src)
        date_str    = meeting_date(src)
        cleaned     = strip_meta_lines(body)
        cons, acts  = classify_body(cleaned, lang, date_str)

        # Fallback: if no action was recognized but the body has prose,
        # preserve the first non-empty paragraph as a "notes" action so
        # the resolution is not rendered empty. (Handles verbs not in
        # the prefix list, e.g. "Le Comité a rejeté l'appel..." .)
        if acts.empty? && cleaned.strip.length > 10
          first_para = cleaned.strip.split(/\n\s*\n/).first || cleaned.strip
          first_para = first_para.strip
          acts << {
            "type"    => "notes",
            "message" => convert_tables(first_para),
            "dates"   => [{ "start" => date_str, "kind" => "effective" }],
          } unless first_para.empty?
        end

        # Title: prefer "Agenda item N" as the canonical reference, which
        # is how OIML cites resolutions. Falls back to a synthesized
        # verb-led snippet, but treats source deletion markers
        # ("(Removed)", "(Supprimée)", ...), header echoes like
        # "(Agenda item 1)" / "(Point 12 ...)", and empty bodies as
        # "(untitled)" — the literal marker for "no real title in
        # source".
        title = agenda_item ? "Agenda item #{agenda_item}" : synthesize_title(acts)

        res << {
          "identifier"  => ident,
          "doi"         => compute_doi(src, ident),
          "urn"         => compute_urn(src, ident),
          "subject"     => subject_str,
          "title"       => title,
          "dates"       => [{ "start" => meeting_date(src), "kind" => "decision" }],
          "agenda_item" => agenda_item,
          "considerations" => cons,
          "actions"     => acts,
          "approvals"   => [],
        }
      end

      [res, deferred]
    end


    # Parse narrative minutes/decisions format. Supports both:
    #   * CIML 39+ "## N <title>" or "## N.M <title>"    (Arabic numerals)
    #   * CIML 15-29 "## <Roman> — <title>"               (Roman + optional sub-letter)
    #     e.g. "## IV b — Title"                          (Roman + sub-letter)
    # Each numbered section becomes a resolution; each body paragraph
    # starting with "The Committee [verb]" becomes an action.
    # Match narrative section headers in either form:
    #   "## IV — Title"      (Roman + em-dash, CIML 15-29 style)
    #   "## IV b — Title"    (Roman + sub-letter)
    #   "## 1 Title"         (Arabic, CIML 39+ style)
    #   "## 2.1. Title"      (Arabic with sub-number)
    NARRATIVE_SECTION_RE = /\A##\s+([IVX]+(?:\s?[a-z])?|\d+(?:\.\d+)?)\s*(?:[—–-]+|\.?)\s+(.+)/

    def self.parse_narrative(md, src, lang)
      res = []
      date_str = meeting_date(src)

      body = pick_narrative_body(md)
      # Cut at ANNEX
      if (m = body.match(/\n#\s+ANNEX\b/i))
        body = body[0...m.begin(0)]
      end

      current_header = nil
      current_body = []

      body.each_line do |line|
        if line =~ NARRATIVE_SECTION_RE
          if current_header && !looks_like_toc?(current_body)
            res << build_narrative_resolution(current_header, current_body, src, date_str, lang)
          end
          current_header = [$1, $2.strip]
          current_body = []
        elsif current_header
          current_body << line
        end
      end
      if current_header && !looks_like_toc?(current_body)
        res << build_narrative_resolution(current_header, current_body, src, date_str, lang)
      end

      [res, 0]
    end

    # Decide which slice of the markdown to walk for narrative sections.
    #   * Has "## MINUTES" + "## DECISIONS": parse MINUTES → DECISIONS
    #     (the narrative minutes between the two markers).
    #   * Has only "## DECISIONS" with narrative before it: parse
    #     pre-DECISIONS (e.g. CIML 24-style narrative + recap).
    #   * Has only "## DECISIONS" with no narrative before: parse
    #     POST-DECISIONS (e.g. CIML 38 dedicated decisions doc).
    #   * If POST-DECISIONS starts with "## CIML YYYY POINT/ITEM N"
    #     formal recap headers, return empty (skip — unparseable format).
    #   * No "## DECISIONS" at all: walk whole doc (CIML 15-29 style).
    def self.pick_narrative_body(md)
      minutes_re = /(^|\n)#+\s+(?:MINUTES|COMPTE\s+RENDU\s+DES\s+D[ÉE]BATS)\b/i
      decisions_re = /(^|\n)(#+\s+D[ÉE]CISIONS\b[^\n]*)/i

      minutes_m = md.match(minutes_re)
      decisions_m = md.match(decisions_re)

      if minutes_m && decisions_m && minutes_m.begin(0) < decisions_m.begin(0)
        # Standard narrative minutes between MINUTES and DECISIONS markers.
        return md[minutes_m.end(0)...decisions_m.begin(0)]
      end

      return md unless decisions_m

      pre = md[0...decisions_m.begin(0)]
      # If pre-DECISIONS has numbered/Roman section headers, treat it as
      # the narrative and parse it.
      if pre =~ /\n##\s+(?:\d+|[IVX]+\s)/
        return pre
      end

      # No narrative before DECISIONS — inspect what comes after.
      after = md[decisions_m.end(0)..]
      first_section = after.each_line.lazy.drop_while do |line|
        line !~ /\A##\s+/
      end.first

      if first_section && first_section =~ /\A##\s+.*CIML\s+\d{4}[\s-]+(?:POINT|ITEM)/i
        # Formal recap with POINT/ITEM headers — unparseable, skip.
        ""
      else
        after
      end
    end

    # Heuristic: a body is a SOMMAIRE/TOC fragment if most of its
    # non-empty lines look like list entries ("N. ...", "N.M. ...", "a) ...").
    # Such sections are OCR artifacts (TOC lines mis-rendered as ## headers)
    # and should be skipped.
    def self.looks_like_toc?(body_lines)
      non_empty = body_lines.map(&:strip).reject(&:empty?)
      return true if non_empty.empty?
      list_pat = /\A(?:\d+\.\s+|\d+\.\d+\.?\s+|[a-z]\)\s+|[IVX]+\s+[—–-])/
      list_lines = non_empty.count { |line| line =~ list_pat }
      (list_lines.to_f / non_empty.size) > 0.5
    end

    # Convert a Roman numeral string to its integer value. Only handles
    # I/X/V (sufficient for CIML section numbers, max ~30).
    def self.roman_to_int(s)
      vals = { "I" => 1, "V" => 5, "X" => 10 }
      total = 0
      prev  = 0
      s.chars.reverse.each do |c|
        v = vals[c] || 0
        v < prev ? total -= v : total += v
        prev = v
      end
      total
    end

    # Normalize a captured section-number token into the canonical form
    # used in identifiers. Examples:
    #   "IV"    → "4"
    #   "IV b"  → "4b"
    #   "2.1"   → "2.1"
    #   "1"     → "1"
    def self.canonical_section_number(token)
      if token =~ /\A([IVX]+)\s?([a-z])?\z/
        n = roman_to_int($1)
        return $2 ? "#{n}#{$2}" : n.to_s
      end
      token
    end

    def self.build_narrative_resolution(header, body_lines, src, date_str, lang = :en)
      raw_number, title = header
      kind_label = src["kind"] == "ciml" ? "CIML" : "Conference"
      number = canonical_section_number(raw_number)
      identifier = "#{kind_label}/#{src['year']}/#{number}"

      paragraphs = body_lines.join.split(/\n\s*\n/).map(&:strip).reject(&:empty?)
      acts = []
      paragraphs.each do |para|
        clean = para.gsub(/\A[-*]\s+/, "")
        verb_type = classify_narrative_verb(clean)
        if verb_type
          msg = convert_tables(clean)
          acts << {
            "type"    => verb_type,
            "message" => msg,
            "dates"   => [{ "start" => date_str, "kind" => "effective" }],
          }
        end
      end

      # Fallback: if no verb was recognized but the section had body content,
      # preserve it as a "notes" action so the body isn't lost.
      if acts.empty? && paragraphs.any?
        first = paragraphs.first
        msg = convert_tables(first)
        acts << {
          "type"    => "notes",
          "message" => msg,
          "dates"   => [{ "start" => date_str, "kind" => "effective" }],
        }
      end

      title_str = title.to_s.strip
      title_str = title_str[0...100] + "…" if title_str.size > 100
      # Treat deletion markers, header echoes, and empty titles as
      # the literal "(untitled)" placeholder.
      if title_str.empty? || deletion_marker?(title_str) || header_echo?(title_str)
        title_str = "(untitled)"
      end

      # Subject: extract the issuer phrase ("The Committee", "Le Comité",
      # "La Conférence", ...) directly from the section body if present.
      # Preserves source text verbatim — no normalization to canonical
      # labels. Returns nil when the body is verb-led and contains no
      # explicit subject (which is fine for the optional field).
      subject_str = extract_subject(body_lines.join, lang, src)

      {
        "identifier"     => identifier,
        "doi"            => compute_doi(src, identifier),
        "urn"            => compute_urn(src, identifier),
        "subject"        => subject_str,
        "title"          => title_str.empty? ? "(Untitled)" : title_str,
        "dates"          => [{ "start" => date_str, "kind" => "decision" }],
        "considerations" => [],
        "actions"        => acts,
        "approvals"      => [],
      }
    end

    NARRATIVE_VERBS = [
      ["took note",                  "notes"],
      ["takes note",                 "notes"],
      ["noted",                      "notes"],
      ["notes",                      "notes"],
      ["approved",                   "approves"],
      ["approves",                   "approves"],
      ["instructed",                 "instructs"],
      ["instructs",                  "instructs"],
      ["endorsed",                   "endorses"],
      ["endorses",                   "endorses"],
      ["thanked",                    "thanks"],
      ["thanks",                     "thanks"],
      ["decided",                    "decides"],
      ["decides",                    "decides"],
      ["renewed",                    "renews"],
      ["welcomed",                   "welcomes"],
      ["wishes",                     "wishes"],
      ["wished",                     "wishes"],
      ["set the deadline",           "sets"],
      ["requested",                  "requests"],
      ["gave its approval",          "approves"],
      ["expressed its appreciation", "thanks"],
    ].freeze

    FR_NARRATIVE_VERBS = [
      ["a approuv[ée]",          "approves"],
      ["approuve",               "approves"],
      ["a not[ée]",              "notes"],
      ["note",                   "notes"],
      ["a pris note",            "notes"],
      ["a charg[ée]",            "instructs"],
      ["a instruit",             "instructs"],
      ["a adopt[ée]",            "approves"],
      ["a soulign[ée]",          "notes"],
      ["a remerci[ée]",          "thanks"],
      ["a d[ée]cid[ée]",         "decides"],
      ["a renouvel[ée]",         "renews"],
      ["a accueilli",            "welcomes"],
      ["a pri[ée]",              "requests"],
      ["a exprim[ée]",           "notes"],
      ["a fix[ée]",              "sets"],
      ["a approuv[ée] le principe", "approves"],
      ["a donn[ée] son accord",  "approves"],
      ["a souhait[ée]",          "wishes"],
    ].freeze

    def self.classify_narrative_verb(para)
      after = nil
      if para =~ /\AThe Committee\s+/i
        after = $'.strip
      elsif para =~ /\ALe Comit[ée]\s+/i
        after = $'.strip
      else
        return nil
      end
      # Try French verbs first if the para is in French
      if para =~ /\ALe Comit[ée]/i
        FR_NARRATIVE_VERBS.each do |(prefix, type)|
          return type if after.downcase.start_with?(prefix)
        end
        return "notes"
      end
      NARRATIVE_VERBS.each do |(prefix, type)|
        return type if after.downcase.start_with?(prefix)
      end
      "notes"
    end
    # Find resolution headers and slice the body that follows each one.
    # Returns array of [header_line, body_until_next_header].
    def self.split_resolution_blocks(md)
      lines = md.split("\n")
      blocks = []
      current_header = nil
      current_body   = []

      lines.each do |line|
        if resolution_header?(line)
          blocks << [current_header, current_body.join("\n")] if current_header
          current_header = line
          current_body   = []
        elsif current_header
          current_body << line
        end
      end
      blocks << [current_header, current_body.join("\n")] if current_header
      blocks
    end

    # A line is a resolution header if it matches:
    #   "## Resolution Conference/YYYY/NN"
    #   "## Resolution CIML/YYYY/NN"
    #   "## Resolution no.N"        (older)
    #   "## Résolution n° N"        (FR)
    def self.resolution_header?(line)
      # Markdown header form: "## Resolution ..." / "## Résolution ..."
      return true if line =~ /\A\#{1,6}\s+(Resolution|R[ée]solution)\b/i
      # Plain-text form (no ## prefix): "Resolution no. 2013/1" / "Résolution n° 1".
      # Require an identifier tail so we don't snag body prose.
      return true if line =~ /\A\s*(Resolution|R[ée]solution)\s+(?:(?:Conference|CIML)\/\d{4}\/\d+[a-z]?|\d{4}\/\d+[a-z]?|no\.?\s*\d+[a-z]?|n[°o]\s*\d+[a-z]?|\d+[a-z]?)/i
      false
    end

    # Parse identifier from header. Returns string like "Conference/2025/01"
    # or "CIML/2022/10" or "<year>/<seq>" for older format. nil if unparsable.
    def self.parse_identifier(header, src)
      return nil unless header
      kind_label = src["kind"] == "ciml" ? "CIML" : "Conference"

      # 1. Modern with body prefix: "Conference/YYYY/NN" or "CIML/YYYY/NN"
      if m = header.match(/(Conference|CIML)\/(\d{4})\/(\d+[a-z]?)/i)
        return "#{kind_label}/#{m[2]}/#{m[3]}"
      end

      # 2. Year/sequence anywhere in the header: "Resolution 2019/19", "Resolution no. 2016/3"
      if m = header.match(/\b(\d{4})\/(\d+[a-z]?)\b/)
        return "#{kind_label}/#{m[1]}/#{m[2]}"
      end

      # 3. Older: "Resolution no.N" / "Résolution n° N" — use meeting year from manifest
      if m = header.match(/n[°o]\.?\s*(\d+[a-z]?)\b/i)
        return "#{kind_label}/#{src['year']}/#{m[1]}"
      end

      # 4. Bare sequence: "Resolution 1" / "Résolution 4" — use meeting year from manifest
      if m = header.match(/\b(?:Resolution|R[ée]solution)\s+(\d+[a-z]?)\b/)
        return "#{kind_label}/#{src['year']}/#{m[1]}"
      end

      nil
    end

    def self.extract_agenda_item(body)
      # EN: "Agenda item 2.3"  /  "[Agenda item 2.3]"
      m = body.match(/^\s*\[?\s*Agenda item\s+([\d\.]+)/i)
      return m[1] if m
      # FR: "[Point 2.2 de l'ordre du jour]"  /  "Point 2.2 de l'ordre du jour"
      m = body.match(/^\s*\[?\s*Point\s+([\d\.]+)/i)
      m && m[1]
    end

    # Canonical subject kinds recognized in resolution bodies.
    # Each entry: [regex_pattern, kind_symbol].
    # `kind` is one of :committee, :conference, :bureau, :council.
    # Returns the localized subject label via lookup against
    # `SUBJECT_LABELS_BY_KIND`.
    SUBJECT_PATTERNS = [
      [/\A[ \t]*the[ \t]+conference[ \t]*[,.;]?\z/i,         :conference],
      [/\A[ \t]*the[ \t]+committee[ \t]*[,.;]?\z/i,          :committee],
      [/\A[ \t]*the[ \t]+bureau[ \t]*[,.;]?\z/i,             :bureau],
      [/\A[ \t]*the[ \t]+council[ \t]*[,.;]?\z/i,            :council],
      [/\A[ \t]*la[ \t]+conf[ée]rence[ \t]*[,.;]?\z/i,       :conference],
      [/\A[ \t]*le[ \t]+comit[ée][ \t]*[,.;]?\z/i,           :committee],
      [/\A[ \t]*le[ \t]+bureau[ \t]*[,.;]?\z/i,              :bureau],
      [/\A[ \t]*le[ \t]+conseil[ \t]*[,.;]?\z/i,             :council],
    ].freeze

    # Per-language canonical labels by subject kind. Returns the
    # display string that goes into Resolution.localization.subject.
    #
    # The subject is the issuer of the resolution AS STATED IN THE SOURCE
    # TEXT, not an abbreviation or category. So a body that starts with
    # "The Committee approves..." gets subject="The Committee"; one
    # that starts with "Le Comité a approuvé..." gets subject="Le Comité".
    SUBJECT_LABELS_BY_KIND = {
      committee:   { en: "The Committee",  fr: "Le Comité" },
      conference:  { en: "The Conference", fr: "La Conférence" },
      bureau:      { en: "The Bureau",     fr: "Le Bureau" },
      council:     { en: "The Council",    fr: "Le Conseil" },
    }.freeze

    # Detect the subject kind from a resolution body. Walks each line,
    # strips whitespace + zero-width chars, and matches against the
    # canonical subject patterns. Returns the kind symbol or :unknown.
    def self.detect_subject_kind(body)
      body.each_line do |raw|
        line = raw.strip.gsub(/​/, "").gsub(/\s+/, " ")
        SUBJECT_PATTERNS.each do |(re, kind)|
          return kind if line =~ re
        end
      end
      :unknown
    end

    # Locate the first issuer phrase ("The Committee", "Le Comité",
    # "La Conférence", ...) in the body and return its literal text.
    # The literal text is preserved exactly as it appears — case,
    # accent, and any surrounding punctuation from the source are kept,
    # so a source with "le Comité" yields subject "le Comité", not
    # "Le Comité". Returns nil if no issuer phrase is found (e.g. a
    # verb-led formal resolution with no explicit subject).
    #
    # The `src` argument is used only when the source body has no
    # issuer phrase. In that case we fall back to a parenthesised
    # placeholder — "(The CIML)" / "(Le CIML)" / "(The Conference)" /
    # "(La Conférence)" — to signal that the subject is inferred from
    # the meeting kind, not extracted from the body text.
    def self.extract_subject(body, lang, src = nil)
      phrases =
        case lang
        when :fr
          [
            /\bLe\s+Comit[ée]\b/,        /\ble\s+Comit[ée]\b/,
            /\bLa\s+Conf[ée]rence\b/,    /\bla\s+Conf[ée]rence\b/,
            /\bLe\s+Bureau\b/,           /\ble\s+Bureau\b/,
            /\bLe\s+Conseil\b/,          /\ble\s+Conseil\b/,
          ]
        else
          [
            /\bThe\s+Committee\b/,       /\bthe\s+Committee\b/,
            /\bThe\s+Conference\b/,      /\bthe\s+Conference\b/,
            /\bThe\s+Bureau\b/,          /\bthe\s+Bureau\b/,
            /\bThe\s+Council\b/,         /\bthe\s+Council\b/,
          ]
        end
      phrases.each do |pat|
        m = body.match(pat)
        return m[0] if m
      end
      inferred_subject(src, lang)
    end

    # Parenthesised placeholder used when the source body has no
    # explicit issuer phrase — signals "inferred from meeting kind".
    def self.inferred_subject(src, lang)
      meeting_kind = (src && src["kind"]) || "ciml"
      if meeting_kind == "conference"
        lang == :fr ? "(La Conférence)" : "(The Conference)"
      else
        lang == :fr ? "(Le CIML)" : "(The CIML)"
      end
    end

    # Drop metadata lines (agenda item, subject marker) from body, and
    # normalize GLM-OCR's tendency to render verbs as markdown headers
    # inside a resolution body (e.g. "## Resolves", "## Instructs the Bureau to").
    def self.strip_meta_lines(body)
      out = []
      body.each_line do |line|
        stripped = line.strip.gsub(/​/, "")
        next if stripped =~ /\AAgenda item\b/i
        # Drop any subject marker line detected by detect_subject_kind.
        # This is more lenient than the prior regex — handles OCR
        # whitespace + trailing punctuation variants.
        if SUBJECT_PATTERNS.any? { |(re, _)| stripped =~ re }
          next
        end
        # Strip leading markdown header marks. Within a single resolution body
        # there should be no real section breaks (those were used as resolution
        # delimiters earlier in the pipeline). "## Foo" → "Foo".
        line = line.sub(/\A(\s*)\#{1,6}\s+/, "\\1")
        # Strip leading numbered sub-item markers like "1. 1 ", "1.2 ", "2.3 "
        # used in joint decision docs (Conf 12) and some minutes-style bodies.
        line = line.sub(/\A(\s*)\d+\.\s*\d+\s+/, "\\1")
        out << line
      end
      out.join
    end

    # Walk the body and group lines into consideration/action blocks by
    # their leading verb. Returns [considerations, actions] arrays of
    # { "type" => ..., "message" => ..., "dates" => [...] }.
    def self.classify_body(body, lang, date_str)
      cons_prefixes = lang == :fr ? FR_CONSIDERATION_PREFIXES : CONSIDERATION_PREFIXES
      act_prefixes  = lang == :fr ? FR_ACTION_PREFIXES       : ACTION_PREFIXES

      blocks = group_by_leading_verb(body)
      cons = []
      acts = []
      blocks.each do |(verb_line, body_lines)|
        type, kind = classify_verb(verb_line, cons_prefixes, act_prefixes)
        next unless type
        msg = reconstruct_message(verb_line, body_lines)
        msg = convert_tables(msg)
        msg = msg.strip
        next if msg.empty?
        entry = {
          "type"    => type,
          "message" => msg,
          "dates"   => [{ "start" => date_str, "kind" => "effective" }],
        }
        if kind == "consideration"
          cons << entry
        else
          acts << entry
        end
      end
      [cons, acts]
    end

    # Split body into [verb_line, continuation_lines] groups. A new group
    # starts whenever a line begins with a known verb prefix. Non-verb lines
    # attach to the most recent group.
    # Optional "The Committee / The Conference / The Bureau / Le Comité / ..."
    # prefix that appears in older formal resolutions where the subject and
    # the verb are on the same line (no comma after the subject).
    SUBJECT_LEAD = /
      \A
      (?:The\s+(?:Committee|Conference|Bureau|Council)\s+
       |Le\s+Comit[ée]\s+
       |La\s+Conf[ée]rence\s+)
    /ix

    def self.group_by_leading_verb(body)
      cons_prefixes = CONSIDERATION_PREFIXES + FR_CONSIDERATION_PREFIXES
      act_prefixes  = ACTION_PREFIXES + FR_ACTION_PREFIXES
      all_prefixes  = (cons_prefixes + act_prefixes).map(&:first).sort_by(&:length).reverse
      # Build one regex that allows an optional subject lead before the verb.
      verb_alternatives = all_prefixes.map { |p| Regexp.escape(p) }.join("|")
      verb_with_subject_re = /\A(?:The\s+(?:Committee|Conference|Bureau|Council)\s+|Le\s+Comit[ée]\s+|La\s+Conf[ée]rence\s+)?(?:#{verb_alternatives})/i

      groups = []
      current_verb_line = nil
      current_body = []

      body.each_line do |line|
        next if line.strip.empty?
        next if line =~ /\A#+\s/
        if line.strip =~ verb_with_subject_re
          groups << [current_verb_line, current_body] if current_verb_line
          current_verb_line = line
          current_body = []
        elsif current_verb_line
          current_body << line
        end
      end
      groups << [current_verb_line, current_body] if current_verb_line
      groups
    end

    def self.classify_verb(verb_line, cons_prefixes, act_prefixes)
      return [nil, nil] unless verb_line
      # Strip a leading subject marker so "The Committee approved" classifies
      # the same as "approved".
      stripped = verb_line.strip.sub(SUBJECT_LEAD, "")
      stripped_lower = stripped.downcase
      cons_prefixes.each do |(prefix, type)|
        return [type, "consideration"] if stripped_lower.start_with?(prefix.downcase)
      end
      act_prefixes.each do |(prefix, type)|
        return [type, "action"] if stripped_lower.start_with?(prefix.downcase)
      end
      [nil, nil]
    end

    def self.reconstruct_message(verb_line, body_lines)
      # Preserve the leading verb line + all continuation lines.
      # Strip trailing blank lines.
      ([verb_line] + body_lines).join.strip
    end

    # Convert any HTML <table>...</table> blocks to AsciiDoc |=== tables.
    def self.convert_tables(text)
      text.gsub(/<table[^>]*>.*?<\/table>/m) do |html|
        html_table_to_asciidoc(html)
      end
    end

    def self.html_table_to_asciidoc(html)
      rows = []
      html.scan(/<tr[^>]*>(.*?)<\/tr>/m) do |(tr_inner)|
        cells = tr_inner.scan(/<t[dh][^>]*>(.*?)<\/t[dh]>/m).flatten
        rows << cells.map { |c| c.strip.gsub(/\s+/, " ") }
      end
      return "" if rows.empty?
      cols = rows.map(&:size).max
      out  = ["|==="]
      rows.each do |row|
        cells = row.fill("", row.size...cols)
        out << "| " + cells.join(" | ")
      end
      out << "|==="
      out.join("\n")
    end

    # Derive a short title from the first action: take the verb stem and the
    # first sentence (truncated to ~14 words). Returns the literal marker
    # "(untitled)" when no real title can be synthesized — this includes
    # empty actions AND the various "no real title" signals from source:
    #   * deletion markers: "(Removed)", "(Supprimée)", "(Annulé)", ...
    #   * header echoes: "(Agenda item N)", "(Point N ...)"
    # All are replaced with "(untitled)" rather than propagated as titles.
    def self.synthesize_title(actions)
      return "(untitled)" if actions.empty?
      msg = actions.first["message"].to_s.strip
      # Cut at first sub-item list marker (a), b), ...) — those belong in the body.
      msg = msg.sub(/\s+\(?[a-z]\)\s.*\z/m, "")
      # Treat deletion markers and header echoes as untitled — the
      # source has no real title content for this resolution slot.
      return "(untitled)" if deletion_marker?(msg) || header_echo?(msg)
      # Take the first 14 whitespace-separated tokens (resists "M." truncation).
      words = msg.split
      title = words.first(14).join(" ")
      title = title.sub(/[,;:]\z/, "")
      title = title[0...100] + "…" if title.size > 100
      title.empty? ? "(untitled)" : title
    end

    # Source deletion markers — a short parenthesized phrase that means
    # "this resolution slot was removed". Examples seen in the wild:
    #   (Removed)  (Deleted)  (Cancelled)  (Canceled)  (Striked)
    #   (Supprimée)  (Supprimé)  (Annulée)  (Annulé)  (Biffée)
    #   (Removed at the ... Meeting)  (Supprimée — voir ...)
    # These are not titles — we treat them as a signal that the source
    # has no real title and surface "(untitled)" instead.
    DELETION_MARKERS_RE = /\A\(\s*(?:removed|deleted|cancelled|canceled|striked|strikethrough|supprim(?:ée?|é|e)?|annul(?:ée?|é|e)?|biff(?:ée?|é|e)?|ray(?:ée?|é|e)?)\b[^)]*\)\z/i

    def self.deletion_marker?(text)
      t = text.to_s.strip
      return false if t.empty?
      DELETION_MARKERS_RE.match?(t)
    end

    # Header echo — when the body just repeats the agenda-item header
    # that the OCR captured twice (e.g., "(Agenda item 1)" or
    # "(Point 12 de l'ordre du jour)" without any real content).
    # These are not titles either; surface as "(untitled)".
    HEADER_ECHO_RE = /\A\(\s*(?:agenda\s+item|point)\b[^)]*\)\z/i

    def self.header_echo?(text)
      t = text.to_s.strip
      return false if t.empty?
      HEADER_ECHO_RE.match?(t)
    end

    def self.meeting_date(src)
      # Use the real meeting date extracted from the OCR cover page if present
      # (see scripts/extract_dates.rb). Fall back to YYYY-01-01 placeholder.
      src["date_start"] || "#{src['year']}-01-01"
    end

    # Per the URN spec at ~/src/oimlsmart/smart/data/oiml-urn-specification.adoc:
    #   urn:oiml:doc:conf:resolution:<session>.<seq>
    #   urn:oiml:doc:ciml:resolution:<year>-<seq>
    def self.compute_urn(src, identifier)
      kind, year, seq = parse_identifier_parts(identifier, src)
      seq_padded = pad_seq(seq)
      case kind
      when "Conference" then "urn:oiml:doc:conf:resolution:#{src['session']}.#{seq_padded}"
      when "CIML"       then "urn:oiml:doc:ciml:resolution:#{year}-#{seq_padded}"
      else "urn:oiml:doc:#{kind.downcase}:resolution:#{year}-#{seq_padded}"
      end
    end

    # Per user direction (TODO.cleanups/01-doi-urn.md):
    #   Conference: 10.63493/resolutions/conf<YYYY><NN>
    #   CIML:        10.63493/resolutions/ciml<YYYY><NN>
    def self.compute_doi(src, identifier)
      kind, year, seq = parse_identifier_parts(identifier, src)
      seq_padded = pad_seq(seq)
      prefix = kind == "Conference" ? "conf" : "ciml"
      "10.63493/resolutions/#{prefix}#{year}#{seq_padded}"
    end

    # identifier is "Conference/2025/01" or "CIML/2025/44" or "CIML/2004/2.1"
    def self.parse_identifier_parts(identifier, src)
      if identifier =~ /\A(Conference|CIML)\/(\d{4})\/(.+)\z/
        [$1, $2, $3]
      else
        # Fallback for unexpected shapes (narrative-era identifiers always
        # include the body prefix, so this should rarely fire)
        kind_label = src["kind"] == "ciml" ? "CIML" : "Conference"
        [kind_label, src["year"].to_s, identifier.to_s]
      end
    end

    # Zero-pad a sequence token to 2 digits if it's purely numeric.
    # Alphanumeric seqs (e.g. "4a") are preserved as-is.
    def self.pad_seq(seq)
      return seq if seq.to_s =~ /\A\d+\z/ && seq.to_s.length >= 2
      return seq.to_s.rjust(2, "0") if seq.to_s =~ /\A\d+\z/
      seq.to_s
    end

    def self.render_collection(src, out_slug, lang, resolutions)
      kind     = src["kind"]
      number   = src["kind"] == "ciml" ? src["meeting"] : src["session"]
      body     = src["kind"] == "ciml" ? "CIML Meeting" : "OIML Conference"
      urn_kind = src["kind"] == "ciml" ? "ciml" : "conference"
      if src["lang"] == "bilingual"
        ord = number_to_ordinal(number, lang)
        title = lang == :fr ? "Résolutions #{ord} #{body} (#{src['year']})" : "Resolutions of the #{ord} #{body} (#{src['year']})"
      else
        title = src["title"].to_s
      end
      venue = src["venue"]

      date_start = src["date_start"] || "#{src['year']}-01-01"
      date_end   = src["date_end"]   || date_start
      dates_yaml = if date_start == date_end
        "  dates:\n  - start: '#{date_start}'\n    kind: meeting"
      else
        "  dates:\n  - start: '#{date_start}'\n    end: '#{date_end}'\n    kind: meeting"
      end

      <<~YAML
        # yaml-language-server: $schema=#{SCHEMA_URL}
        # Auto-generated from reference-docs/.ocr/md/#{src['slug']}.md by scripts/author_yaml.rb
        # Source PDF: #{source_pdf_path(src)}
        # Meeting URN: urn:oiml:#{urn_kind}:meeting:#{out_slug}
        # Language: #{lang}
        ---
        metadata:
          title: #{yaml_escape(title)}
        #{dates_yaml}
          source: OIML #{kind == 'ciml' ? 'CIML' : 'Conference'} Secretariat (BIML)
          venue: #{yaml_escape(venue)}
          city: #{yaml_escape(src['city'].to_s)}
          country_code: #{yaml_escape(src['country_code'].to_s)}
          language: #{lang}
        resolutions:
      YAML
        .concat(resolutions.map { |r| render_resolution(r) }.join("\n"))
    end

    def self.render_resolution(r)
      indent = "  "
      lines = []
      lines << "#{indent}- identifier: #{yaml_escape(r['identifier'])}"
      lines << "#{indent}  doi: #{yaml_escape(r['doi'])}" if r["doi"]
      lines << "#{indent}  urn: #{yaml_escape(r['urn'])}" if r["urn"]
      lines << "#{indent}  subject: #{yaml_escape(r['subject'])}"
      lines << "#{indent}  title: #{yaml_escape(r['title'])}"
      lines << "#{indent}  dates:"
      r["dates"].each do |d|
        lines << "#{indent}  - start: '#{d['start']}'"
        lines << "#{indent}    kind: #{d['kind']}"
      end
      lines << "#{indent}  agenda_item: '#{r['agenda_item']}'" if r["agenda_item"]
      if r["considerations"].any?
        lines << "#{indent}  considerations:"
        r["considerations"].each { |c| lines << render_action_like(c, indent + "  ") }
      else
        lines << "#{indent}  considerations: []"
      end
      if r["actions"].any?
        lines << "#{indent}  actions:"
        r["actions"].each { |a| lines << render_action_like(a, indent + "  ") }
      else
        lines << "#{indent}  actions: []"
      end
      lines.join("\n")
    end

    def self.render_action_like(entry, indent)
      out = []
      out << "#{indent}- type: #{entry['type']}"
      out << "#{indent}  message: |"
      entry["message"].to_s.split("\n").each do |line|
        out << "#{indent}    #{line}"
      end
      out << "#{indent}  dates:"
      entry["dates"].each do |d|
        out << "#{indent}  - start: '#{d['start']}'"
        out << "#{indent}    kind: #{d['kind']}"
      end
      out.join("\n")
    end

    def self.source_pdf_path(src)
      kind = src["kind"] == "ciml" ? "ciml" : "conferences"
      # CIML PDFs were reorganized into ciml/{minutes,resolutions}/ subdirs.
      # Conferences stay flat under conferences/.
      subdir =
        if src["path"]
          src["path"]
        elsif kind == "ciml"
          case src["doc_kind"].to_s
          when "minutes" then "minutes"
          else "resolutions"
          end
        else
          ""
        end
      if subdir.empty?
        "reference-docs/#{kind}/#{src['slug']}.pdf"
      else
        "reference-docs/#{kind}/#{subdir}/#{src['slug']}.pdf"
      end
    end

    def self.number_to_ordinal(n, lang)
      return n.to_s unless n.is_a?(Integer)
      if lang == :fr
        n == 1 ? "1ère" : "#{n}e"
      else
        suf = case n % 100
              when 11..13 then "th"
              else case n % 10
                   when 1 then "st"
                   when 2 then "nd"
                   when 3 then "rd"
                   else "th"
                   end
              end
        "#{n}#{suf}"
      end
    end

    def self.yaml_escape(s)
      s = s.to_s
      # Quote if it contains special chars
      return s if s =~ /\A[A-Za-z0-9 _\-\/\.\(\)']+\.?\z/ && !(s =~ /\A\d/)
      s.inspect.gsub(/\A"|"\z/, '"')
    end
  end
end

ResolutionsData::Author.run if $PROGRAM_NAME == __FILE__
