# frozen_string_literal: true

require "sequel/notion/type_map"

module Sequel
    module Notion
        module Schema
            NOTION_TO_SEQUEL = {
                "title" => :string,
                "rich_text" => :string,
                "number" => :float,
                "select" => :string,
                "multi_select" => :array,
                "status" => :string,
                "date" => :notion_date, # no Sequel typecast: kept as given
                "checkbox" => :boolean,
                "url" => :string,
                "email" => :string,
                "phone_number" => :string,
                "people" => :array,
                "relation" => :array,
                "files" => :array,
                "formula" => :string,
                "created_time" => :string,
                "last_edited_time" => :string
            }.freeze

            # Columns every row carries, besides the data source properties
            PAGE_COLUMNS = [
                [:id,       { type: :string,  db_type: "page_id",
                              primary_key: true, allow_null: false }],
                [:in_trash, { type: :boolean, db_type: "in_trash",
                              allow_null: false }]
            ].freeze

            # Rollup functions by the kind of value they give; any other
            # (date_range, a new one) is unknown and not filterable
            ROLLUP_KINDS = {
                "array" => %w[show_original show_unique],
                "date" => %w[earliest_date latest_date],
                "number" => %w[count count_values empty not_empty unique
                               percent_empty percent_not_empty sum average
                               median min max range checked unchecked
                               percent_checked percent_unchecked
                               count_per_group percent_per_group]
            }.freeze

            module_function

            def rollup_kind(prop)
                function = prop.dig("rollup", "function")
                ROLLUP_KINDS.find { |_, fns| fns.include?(function) }&.first
            end

            # Data source properties => Sequel schema rows
            def notion_to_sequel(properties)
                PAGE_COLUMNS.map { |name, info| [name, info.dup] } +
                    properties.map do |name, prop|
                        [name.to_sym, column(prop["type"])]
                    end
            end

            def column(notion_type)
                { type: NOTION_TO_SEQUEL.fetch(notion_type, :string),
                  generated: TypeMap::READ_ONLY_TYPES.include?(notion_type),
                  db_type: notion_type,
                  notion_type: notion_type,
                  allow_null: true,
                  default: nil,
                  primary_key: false }
            end
        end
    end
end
