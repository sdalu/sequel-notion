# frozen_string_literal: true

require_relative "notion_file"
require_relative "type_map_builders"
require_relative "type_map_extractors"

module Sequel
    module Notion
        module TypeMap
            module_function

            # Notion property types that the Notion API never accepts on write.
            READ_ONLY_TYPES = %w[
                formula rollup created_time last_edited_time
                created_by last_edited_by unique_id button verification
            ].freeze

            # Writable Notion type => the builder for its value
            BUILDERS = {
                "title" => :build_rich_text,
                "rich_text" => :build_rich_text,
                "number" => :build_number,
                "select" => :build_select,
                "status" => :build_select,
                "multi_select" => :build_multi_select,
                "date" => :build_date,
                "checkbox" => :build_checkbox,
                "url" => :build_string,
                "email" => :build_string,
                "phone_number" => :build_string,
                "relation" => :build_relation,
                "people" => :build_people,
                "files" => :build_files
            }.freeze

            # Notion page → flat Ruby hash
            def page_to_row(page)
                row = { id: page["id"], in_trash: page["in_trash"] }

                (page["properties"] || {}).each do |name, prop|
                    row[name.to_sym] = extract_value(prop)
                end

                row
            end

            # Flat Ruby hash → Notion properties payload
            #
            # +prop_types+ maps property NAME (String) to Notion TYPE
            # (String), e.g. {"Name" => "title", "Status" => "status"}.
            # +hash+ keys may be Symbols or Strings.
            def row_to_properties(hash, prop_types)
                hash.each_with_object({}) do |(key, value), props|
                    name = key.to_s
                    type = prop_types[name]
                    ensure_known_property(name, type, prop_types)
                    props[name] = build_named_property(name, value, type)
                end
            end

            def ensure_known_property(name, type, prop_types)
                return if type

                raise Sequel::Error,
                      "unknown property #{name.inspect}; " \
                      "available: #{prop_types.keys.sort.inspect}"
            end

            # build_property, wrapped so a failure names the property.
            def build_named_property(name, value, type)
                build_property(value, type)
            rescue Sequel::Error => e
                raise Sequel::Error,
                      "property #{name.inspect} (#{type.inspect}): " \
                      "#{e.message}"
            end

            # ----------------------------------------------------------
            # Notion → Ruby
            # ----------------------------------------------------------

            def extract_value(prop)
                type = prop["type"]
                extractor = EXTRACTORS[type]
                return send(extractor, prop) if extractor

                prop[type]
            end

            # ----------------------------------------------------------
            # Ruby → Notion
            # ----------------------------------------------------------

            # Build a single Notion property payload for +value+ given its
            # Notion +type+. Returns {TYPE => value}.
            def build_property(value, type)
                builder = BUILDERS[type]
                return { type => send(builder, value) } if builder

                if READ_ONLY_TYPES.include?(type)
                    raise Sequel::Error,
                          "property type #{type.inspect} is read-only"
                end

                raise Sequel::Error, "unsupported property type #{type.inspect}"
            end
        end
    end
end
