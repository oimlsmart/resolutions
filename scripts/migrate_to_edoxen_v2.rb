#!/usr/bin/env ruby
# frozen_string_literal: true

# One-shot migration: resolutions/*.yaml → canonical Edoxen v2 schema.
#
# Driven by the updated ~/src/mn/edoxen-model (commit 75a5476:
# glossarist-style Localization + SourceUrl models) and
# ~/src/mn/edoxen schema/edoxen.yaml.
#
# What this script changes:
#   * metadata.dates[{start,end,kind}] → metadata.date = <start> (single)
#   * metadata.venue removed (city + country_code carry the location)
#   * Resolution.identifier "CIML/2023/05" → [{prefix:"CIML", number:"2023/05"}]
#   * Resolution.dates[{start,kind}] → [{date, type:"adoption"}]
#   * Action/Consideration dates[{start,kind}] → date_effective:{date,type:"adoption"}
#   * Action/Consideration type mapped into the Edoxen enum
#       notes/acknowledges → remarks
#       endorses/supports/gives_discharge/renews → approves
#       wishes → recommends
#       reaffirms → affirms
#       having_regard_to → having
#   * Resolution.type added when missing (defaults to "resolution" or
#     "decision" based on the source_file slug).
#
# What this script does NOT touch:
#   * doi / urn / agenda_item (already canonical)
#   * title_localized / source_urls (already canonical since commit b8cc2a6)
#   * localizations[*].title / subject / message / considerations / actions
#     at the field-name level — only their child date/type shape changes.
#
# Idempotent: re-running on already-migrated files is a no-op.
# Output is written back over each input file.

require "yaml"

RESOLUTIONS_DIR = File.expand_path("../resolutions", __dir__)

# Verbs that map cleanly to an Edoxen enum value as-is.
VALID_ACTION_TYPES = %w[
  adopts thanks approves decides declares asks invites resolves confirms
  welcomes recommends requests congratulates instructs urges appoints
  calls-upon encourages affirms elects authorizes charges states remarks
  judges sanctions abrogates empowers
].freeze

VALID_CONSIDERATION_TYPES = %w[
  having noting recognizing acknowledging recalling reaffirming considering
  taking-into-account pursuant-to bearing-in-mind emphasizing concerned
  accepts observing referring acting empowers
].freeze

VALID_DATE_TYPES = %w[adoption drafted discussed].freeze

ACTION_VERB_MAP = {
  "notes"           => "remarks",
  "acknowledges"    => "remarks",
  "endorses"        => "approves",
  "supports"        => "approves",
  "gives_discharge" => "approves",
  "renews"          => "approves",
  "wishes"          => "recommends",
  "reaffirms"       => "affirms",
  # already-canonical verbs pass through unchanged
}.freeze

CONSIDERATION_VERB_MAP = {
  "having_regard_to" => "having",
  "having_regard"    => "having",
}.freeze

DATE_KIND_TO_TYPE = {
  "meeting"   => "adoption",
  "decision"  => "adoption",
  "effective" => "adoption",
  "adoption"  => "adoption",
  "drafted"   => "drafted",
  "discussed" => "discussed",
}.freeze

def action_type_slug(slug)
  return slug if VALID_ACTION_TYPES.include?(slug)
  ACTION_VERB_MAP.fetch(slug, "remarks")
end

def consideration_type_slug(slug)
  return slug if VALID_CONSIDERATION_TYPES.include?(slug)
  CONSIDERATION_VERB_MAP.fetch(slug, "considering")
end

# Convert a legacy dates[] item ({start,end,kind}) into a canonical
# ResolutionDate ({date,type}). Returns nil for empty input.
def to_resolution_date(legacy)
  return nil unless legacy.is_a?(Hash)
  date = legacy["date"] || legacy["start"]
  return nil if date.to_s.empty?
  type = legacy["type"] || DATE_KIND_TO_TYPE.fetch(legacy["kind"], "adoption")
  { "date" => date, "type" => type }
end

def migrate_dates_to_date_effective(node)
  return node unless node.is_a?(Hash)
  if node.key?("dates") && !node.key?("date_effective")
    dates = node["dates"]
    legacy = dates.is_a?(Array) ? dates.first : dates
    converted = to_resolution_date(legacy)
    node["date_effective"] = converted if converted
    node.delete("dates")
  end
  node
end

def migrate_action(action)
  return action unless action.is_a?(Hash)
  if action["type"]
    action["type"] = action_type_slug(action["type"])
  end
  migrate_dates_to_date_effective(action)
  action.delete("subject") if action.key?("subject")
  action
end

def migrate_consideration(cons)
  return cons unless cons.is_a?(Hash)
  if cons["type"]
    cons["type"] = consideration_type_slug(cons["type"])
  end
  migrate_dates_to_date_effective(cons)
  cons
end

def migrate_localization(loc)
  return loc unless loc.is_a?(Hash)
  %w[actions considerations].each do |key|
    next unless loc[key].is_a?(Array)
    loc[key] = loc[key].map do |node|
      case key
      when "actions" then migrate_action(node)
      when "considerations" then migrate_consideration(node)
      else node
      end
    end
  end
  loc
end

def migrate_resolution(res, source_file)
  return res unless res.is_a?(Hash)

  # identifier: "CIML/2023/05" → [{prefix:"CIML", number:"2023/05"}]
  ident = res["identifier"]
  if ident.is_a?(String)
    if ident.include?("/")
      prefix, number = ident.split("/", 2)
      res["identifier"] = [{ "prefix" => prefix, "number" => number }]
    else
      res["identifier"] = [{ "prefix" => "", "number" => ident }]
    end
  elsif ident.is_a?(Hash)
    res["identifier"] = [ident]
  elsif ident.nil?
    res["identifier"] = [{ "prefix" => "", "number" => "" }]
  end

  # Resolution.type — default based on source file naming.
  #   *-decisions-* / *_decisions* / *-decisions.yaml → "decision"
  #   everything else → "resolution"
  if res["type"].nil? || res["type"].to_s.empty?
    res["type"] = source_file =~ /(decisions|minutes)/ ? "decision" : "resolution"
  end

  # Resolution.dates[] → [{date, type}]
  if res["dates"].is_a?(Array)
    res["dates"] = res["dates"].map { |d| to_resolution_date(d) }.compact
  end

  res["localizations"] = (res["localizations"] || []).map { |loc| migrate_localization(loc) }
  res
end

def migrate_metadata(meta)
  return meta unless meta.is_a?(Hash)

  # dates[] → single date string
  if meta["dates"].is_a?(Array) && !meta["dates"].empty?
    first = meta["dates"].first
    start = first["start"] || first["date"] if first.is_a?(Hash)
    meta["date"] ||= start
    meta.delete("dates")
  elsif meta["dates"].nil? && meta.key?("date")
    # already canonical
  end

  # venue dropped — city + country_code carry the location
  meta.delete("venue")

  meta
end

def emit_yaml(doc)
  # YAML.dump emits a leading "---\n". Strip it so we can re-attach
  # the original comment preamble.
  body = YAML.dump(doc)
  body.start_with?("---\n") ? body[4..] : body
end

def migrate_file(path)
  raw = File.read(path)
  # Preserve preamble (everything before the first document marker ---).
  preamble = if raw =~ /\A(.*?)(?=^---\s*$)/m
               Regexp.last_match(1)
             else
               ""
             end
  doc = YAML.safe_load(raw, permitted_classes: [Date, Time, DateTime])
  return false unless doc.is_a?(Hash) && doc["resolutions"]

  source_file = File.basename(path, ".yaml")
  doc["metadata"] = migrate_metadata(doc["metadata"] || {})
  doc["resolutions"] = doc["resolutions"].map { |r| migrate_resolution(r, source_file) }

  File.write(path, preamble + "---\n" + emit_yaml(doc))
  true
end

if $PROGRAM_NAME == __FILE__
  files = Dir[File.join(RESOLUTIONS_DIR, "*.yaml")].reject { |p| File.basename(p).start_with?("_") }
  migrated = 0
  files.each do |path|
    if migrate_file(path)
      migrated += 1
      puts "  ✓ #{File.basename(path)}"
    else
      puts "  ⊘ #{File.basename(path)} (skipped — no resolutions key)"
    end
  end
  puts "Migrated #{migrated}/#{files.size} files."
end
