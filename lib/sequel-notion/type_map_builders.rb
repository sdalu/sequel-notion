# frozen_string_literal: true

require_relative "notion_file"

# Ruby → Notion builders for Sequel::Notion::TypeMap, split out here to
# keep type_map.rb's module short. See BUILDERS in type_map.rb for the
# Notion type => builder mapping that dispatches to these.

module Sequel
    module Notion
        module TypeMap
            module_function

            def build_string(value) = value&.to_s

            # title / rich_text: to_s, split into text objects of at most
            # 2000 characters each.
            def build_rich_text(value)
                return [] if value.nil?

                str = value.to_s
                return [] if str.empty?

                str.chars.each_slice(2000).map do |chunk|
                    { "type" => "text", "text" => { "content" => chunk.join } }
                end
            end

            def build_number(value)
                case value
                when nil then nil
                when Integer, Float then value
                when Numeric then value.to_f
                when String then parse_number(value)
                else raise Sequel::Error, "invalid number: #{value.inspect}"
                end
            end

            def parse_number(value)
                Float(value)
            rescue ArgumentError
                raise Sequel::Error, "invalid number: #{value.inspect}"
            end

            def build_select(value)
                return nil if value.nil?

                { "name" => value.to_s }
            end

            def build_multi_select(value)
                return [] if value.nil?

                values = value.is_a?(Array) ? value : [value]
                values.map { |v| { "name" => v.to_s } }
            end

            def build_date(value)
                case value
                when nil then nil
                when String then { "start" => value }
                when Range then build_date_range(value)
                when Date, Time, DateTime then { "start" => value.iso8601 }
                when Hash then build_date_hash(value)
                else raise Sequel::Error, "invalid date value: #{value.inspect}"
                end
            end

            def build_date_range(value)
                { "start" => date_component(value.begin),
                  "end" => date_component(inclusive_end(value)) }
            end

            # Notion's end is inclusive: an exclusive range ends the day
            # before, which only a Date end can say
            def inclusive_end(range)
                last = range.end
                return last if last.nil? || !range.exclude_end?
                return last.prev_day if last.instance_of?(Date)

                raise Sequel::Error,
                      "an exclusive date range must end on a Date: " \
                      "#{range.inspect}"
            end

            def build_date_hash(value)
                start_v = value.key?(:start) ? value[:start] : value["start"]
                end_v = value.key?(:end) ? value[:end] : value["end"]

                result = {}
                result["start"] = date_component(start_v) unless start_v.nil?
                result["end"]   = date_component(end_v) unless end_v.nil?
                result
            end

            def date_component(value)
                value.respond_to?(:iso8601) ? value.iso8601 : value
            end

            def build_checkbox(value)
                case value
                when true, false
                    value
                when nil
                    false
                else
                    raise Sequel::Error,
                          "invalid checkbox value: #{value.inspect}"
                end
            end

            def build_relation(value)
                return [] if value.nil?

                ids = value.is_a?(Array) ? value : [value]
                ids.map { |id| { "id" => id } }
            end

            def build_people(value)
                return [] if value.nil?

                ids = value.is_a?(Array) ? value : [value]
                ids.map { |id| { "object" => "user", "id" => id } }
            end

            def build_files(value)
                return [] if value.nil?

                items = value.is_a?(Array) ? value : [value]
                items.map { |item| build_file(item) }
            end

            def build_file(item)
                case item
                when File then item.to_notion
                when String then File.external(item).to_notion
                else raise Sequel::Error, "invalid file value: #{item.inspect}"
                end
            end
        end
    end
end
