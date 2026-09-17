#!/usr/bin/env ruby
# frozen_string_literal: true

# Migrate OIML YAML data from pre-v1.0 shape to gem v1.0 per-field
# LocalizedString shape. Run once from the repo root:
#
#   ruby scripts/migrate-to-v1.rb
#
# Transforms:
#   resolutions/*.yaml — decisions: localizations[] → per-field LocalizedString
#   meetings/*.yaml    — meetings: strip localizations, language_code → spelling
#   agendas/*.yaml     — merge into meetings, item titles → LocalizedString
#   minutes/*.yaml     — language_code + script → spelling
#
# No data is lost. Every field from every localization is preserved
# in the v1.0 per-field LocalizedString arrays. Actions and
# considerations are merged across localizations by (type, date)
# so each entry carries messages in all available languages.

require "yaml"
require "pathname"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "oiml/resolutions_data"

ROOT = Pathname.new(File.expand_path("../..", __FILE__))

def spelling_of(lang, script)
  return lang unless script
  "#{lang}-#{script}"
end

def to_ls(value, lang, script)
  return nil if value.nil?
  { "spelling" => spelling_of(lang, script), "value" => value }
end

# ── Decision migration ──────────────────────────────────────────

def migrate_decision(d)
  locs = d.delete("localizations")
  return d unless locs && !locs.empty?

  # Per-field LocalizedString (merge ALL localizations, preserve order)
  %w[title subject message considering].each do |field|
    entries = locs.filter_map { |l| to_ls(l[field], l["language_code"], l["script"]) if l[field] }
    d[field] = entries unless entries.empty?
  end

  # Actions: merge across localizations by (type, date_effective)
  action_map = {}
  action_order = []
  locs.each do |l|
    sp = spelling_of(l["language_code"], l["script"])
    (l["actions"] || []).each do |a|
      key = [a["type"], a.dig("date_effective", "date"), a.dig("date_effective", "type")]
      unless action_map.key?(key)
        action_map[key] = a.dup
        action_map[key].delete("message")
        action_map[key]["message"] = []
        action_order << key
      end
      action_map[key]["message"] << { "spelling" => sp, "value" => a["message"] } if a["message"]
    end
  end
  d["actions"] = action_order.map { |k| action_map[k] } unless action_order.empty?

  # Considerations: merge across localizations by (type, date_effective)
  cons_map = {}
  cons_order = []
  locs.each do |l|
    sp = spelling_of(l["language_code"], l["script"])
    (l["considerations"] || []).each do |c|
      key = [c["type"], c.dig("date_effective", "date"), c.dig("date_effective", "type")]
      unless cons_map.key?(key)
        cons_map[key] = c.dup
        cons_map[key].delete("message")
        cons_map[key]["message"] = []
        cons_order << key
      end
      cons_map[key]["message"] << { "spelling" => sp, "value" => c["message"] } if c["message"]
    end
  end
  d["considerations"] = cons_order.map { |k| cons_map[k] } unless cons_order.empty?

  # Approvals: take from first localization (identical across languages)
  d["approvals"] = locs[0]["approvals"] if locs[0]["approvals"]

  d
end

def migrate_metadata(meta)
  return meta unless meta.is_a?(Hash)

  if meta["title_localized"]
    meta["title"] = meta["title_localized"].map do |t|
      { "spelling" => spelling_of(t["language_code"], t["script"]), "value" => t["title"] }
    end
    meta.delete("title_localized")
  elsif meta["title"].is_a?(String)
    meta["title"] = [{ "spelling" => "eng", "value" => meta["title"] }]
  end

  meta
end

# ── Meeting migration ───────────────────────────────────────────

def migrate_meeting(m)
  m.delete("localizations")

  unless m["title"]
    ordinal = m["ordinal"] ? "#{m['ordinal']}#{Oiml::ResolutionsData::Ordinal.suffix(m['ordinal'])} " : ""
    name = m["committee"] || "Meeting"
    m["title"] = [{ "spelling" => "eng", "value" => "#{ordinal}#{name}" }]
  end
  if m["title"].is_a?(String)
    m["title"] = [{ "spelling" => "eng", "value" => m["title"] }]
  end

  if m["general_area"].is_a?(String)
    m["general_area"] = [{ "spelling" => "eng", "value" => m["general_area"] }]
  end

  (m["source_urls"] || []).each do |su|
    next unless su["language_code"]
    su["spelling"] = spelling_of(su["language_code"], su["script"])
    su.delete("language_code")
    su.delete("script")
  end

  (m["minutes"] || []).each do |min|
    next unless min["language_code"]
    min["spelling"] = spelling_of(min["language_code"], min["script"])
    min.delete("language_code")
    min.delete("script")
  end

  m
end

# ── Agenda merge ────────────────────────────────────────────────

def load_agendas
  agendas = {}
  Dir.glob(ROOT.join("agendas", "*.yaml")).each do |f|
    doc = YAML.load_file(f)
    next unless doc && doc["urn"]
    doc["items"] = (doc["items"] || []).map do |item|
      item["title"] = [{ "spelling" => "eng", "value" => item["title"] }] if item["title"].is_a?(String)
      item["description"] = [{ "spelling" => "eng", "value" => item["description"] }] if item["description"].is_a?(String)
      item.delete("urn")
      item
    end
    agendas[doc["urn"]] = doc
  end
  agendas
end

# ── Main ────────────────────────────────────────────────────────

stats = { decisions: 0, meetings: 0, agendas_merged: 0, files: 0 }

# 1. Migrate resolutions
agendas = load_agendas

Dir.glob(ROOT.join("resolutions", "*.yaml")).sort.each do |f|
  doc = YAML.load_file(f)
  next unless doc && doc["decisions"]

  doc["decisions"].each { |d| migrate_decision(d); stats[:decisions] += 1 }
  doc["metadata"] = migrate_metadata(doc["metadata"]) if doc["metadata"]

  File.write(f, doc.to_yaml)
  stats[:files] += 1
end

# 2. Migrate meetings + merge agendas
Dir.glob(ROOT.join("meetings", "*.yaml")).sort.each do |f|
  next if File.basename(f) == "README.md"
  m = YAML.load_file(f)
  next unless m && m["identifier"]

  migrate_meeting(m)
  stats[:meetings] += 1

  agenda = agendas[m["urn"]]
  if agenda
    m["agenda"] = {
      "identifier" => agenda["identifier"],
      "status" => agenda["status"],
      "items" => agenda["items"] || [],
    }
    stats[:agendas_merged] += 1
  end

  File.write(f, m.to_yaml)
  stats[:files] += 1
end

# 3. Migrate standalone minutes
Dir.glob(ROOT.join("minutes", "*.yaml")).sort.each do |f|
  next if File.basename(f) == "README.md"
  doc = YAML.load_file(f)
  next unless doc

  if doc["language_code"]
    doc["spelling"] = spelling_of(doc["language_code"], doc["script"])
    doc.delete("language_code")
    doc.delete("script")
  end

  (doc["sections"] || []).each do |sec|
    %w[title narrative].each do |field|
      next unless sec[field].is_a?(String)
      sec[field] = [{ "spelling" => "eng", "value" => sec[field] }]
    end
  end

  File.write(f, doc.to_yaml)
  stats[:files] += 1
end

puts "Migration complete:"
puts "  Decisions migrated: #{stats[:decisions]}"
puts "  Meetings migrated:  #{stats[:meetings]}"
puts "  Agendas merged:     #{stats[:agendas_merged]}"
puts "  Files written:      #{stats[:files]}"
