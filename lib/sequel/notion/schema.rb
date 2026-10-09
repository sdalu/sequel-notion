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

            module_function

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
