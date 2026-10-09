# frozen_string_literal: true

require_relative "notion_file"

# Notion → Ruby extractors for Sequel::Notion::TypeMap, split out here to
# keep type_map.rb's module short. Types not listed in EXTRACTORS fall
# back to extract_value's default: prop[prop["type"]].

module Sequel
    module Notion
        module TypeMap
            module_function

            # Notion type => the extractor for its property hash. Only
            # types whose value needs more than a plain prop[type] lookup
            # are listed; see extract_value in type_map.rb for the rest.
            EXTRACTORS = {
                "title" => :extract_rich_text,
                "rich_text" => :extract_rich_text,
                "select" => :extract_select,
                "status" => :extract_select,
                "multi_select" => :extract_multi_select,
                "date" => :extract_date,
                "people" => :extract_people,
                "relation" => :extract_relation,
                "formula" => :extract_formula,
                "files" => :extract_files,
                "unique_id" => :extract_unique_id,
                "rollup" => :extract_rollup
            }.freeze

            def extract_rich_text(prop)
                prop[prop["type"]]&.map { it["plain_text"] }&.join
            end

            def extract_select(prop)
                prop.dig(prop["type"], "name")
            end

            def extract_multi_select(prop)
                prop["multi_select"]&.map { it["name"] }
            end

            # The start, or a Range of Strings when there is an end: the
            # Range a write takes
            def extract_date(prop)
                date = prop["date"] || {}
                return date["start"] unless date["end"]

                date["start"]..date["end"]
            end

            # Its value: a number or date, or an Array of the rolled-up
            # values, each read as its own type
            def extract_rollup(prop)
                inner = prop["rollup"]
                return if inner.nil?
                return inner["array"].map { extract_value(it) } if
                    inner["type"] == "array"

                extract_value(inner)
            end

            # As Notion displays it: "TK-62", or "62" with no prefix
            def extract_unique_id(prop)
                id = prop["unique_id"] || {}
                return if id["number"].nil?

                [id["prefix"], id["number"]].compact.join("-")
            end

            def extract_people(prop)
                prop["people"]&.map { it["id"] }
            end

            def extract_relation(prop)
                prop["relation"]&.map { it["id"] }
            end

            def extract_formula(prop)
                extract_value(prop["formula"])
            end

            def extract_files(prop)
                File.from_notion_property(prop)
            end
        end
    end
end
