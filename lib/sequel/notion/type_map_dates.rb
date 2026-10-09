# frozen_string_literal: true

require "date"

# Ruby → Notion date builders for Sequel::Notion::TypeMap, split out of
# type_map_builders.rb to keep that module short.

module Sequel
    module Notion
        module TypeMap
            module_function

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

            # Notion's date needs a start; an endless range leaves the end open
            def build_date_range(value)
                if value.begin.nil?
                    raise Sequel::Error,
                          "a date range needs a start: #{value.inspect}"
                end

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
        end
    end
end
