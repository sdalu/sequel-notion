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
            # 2000 characters each, as Notion counts them (UTF-16 units)
            def build_rich_text(value)
                text_runs(value.to_s).map do |run|
                    { "type" => "text", "text" => { "content" => run } }
                end
            end

            # A character outside the BMP counts two and is never split
            def text_runs(str)
                units = 0
                str.each_char.slice_before do |c|
                    n = c.ord > 0xFFFF ? 2 : 1
                    (units += n) > 2000 && (units = n)
                end.map(&:join)
            end

            def build_number(value)
                case value
                when nil then nil
                when Integer then value
                when Float then finite_number(value)
                when Numeric then finite_number(value.to_f)
                when String then parse_number(value)
                else raise Sequel::Error, "invalid number: #{value.inspect}"
                end
            end

            # JSON has no NaN or Infinity
            def finite_number(value)
                return value if value.finite?

                raise Sequel::Error, "invalid number: #{value.inspect}"
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
                Array(value).map { { "name" => it.to_s } }
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

            # One id or an Array of them; nil is none
            def build_relation(value) = Array(value).map { { "id" => it } }

            def build_people(value)
                Array(value).map { { "object" => "user", "id" => it } }
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
