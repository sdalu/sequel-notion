# frozen_string_literal: true

# frozen_string_literal: true

require_relative "notion_file"

module Sequel
  module Notion
    module TypeMap
      module_function

      # Notion page → flat Ruby hash
      def page_to_row(page)
        row = { id: page["id"], in_trash: page["in_trash"] }

        (page["properties"] || {}).each do |name, prop|
          row[name.to_sym] = extract_value(prop)
        end

        row
      end

      # Flat Ruby hash → Notion properties payload
      def row_to_properties(hash)
        hash.each_with_object({}) do |(key, value), props|
          props[key.to_s] = build_property(value)
        end
      end

      # ----------------------------------------------------------
      # Notion → Ruby
      # ----------------------------------------------------------

      def extract_value(prop)
        case prop["type"]
        when "title"
          prop["title"]&.map { |t| t["plain_text"] }&.join
        when "rich_text"
          prop["rich_text"]&.map { |t| t["plain_text"] }&.join
        when "number"           then prop["number"]
        when "select"           then prop.dig("select", "name")
        when "multi_select"     then prop["multi_select"]&.map { |s| s["name"] }
        when "status"           then prop.dig("status", "name")
        when "date"             then prop.dig("date", "start")
        when "checkbox"         then prop["checkbox"]
        when "url"              then prop["url"]
        when "email"            then prop["email"]
        when "phone_number"     then prop["phone_number"]
        when "people"           then prop["people"]&.map { |p| p["id"] }
        when "relation"         then prop["relation"]&.map { |r| r["id"] }
        when "formula"          then extract_value(prop["formula"])
        when "created_time"     then prop["created_time"]
        when "last_edited_time" then prop["last_edited_time"]
        when "files"            then File.from_notion_property(prop)

        else prop[prop["type"]]
        end
      end

      # ----------------------------------------------------------
      # Ruby → Notion
      # ----------------------------------------------------------

      def build_property(value)
        case value
        when File
          File.to_notion_property([value])
        when String
          { "rich_text" => [{ "text" => { "content" => value } }] }
        when Numeric
          { "number" => value }
        when TrueClass, FalseClass
          { "checkbox" => value }
        when Date, Time
          { "date" => { "start" => value.iso8601 } }
        when Array
          if value.first.is_a?(File)
            File.to_notion_property(value)
          else
            { "multi_select" => value.map { |v| { "name" => v.to_s } } }
          end
        when nil
          {}
        else
          { "rich_text" => [{ "text" => { "content" => value.to_s } }] }
        end
      end
    end
  end
end
