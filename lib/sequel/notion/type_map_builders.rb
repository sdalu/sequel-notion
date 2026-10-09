# frozen_string_literal: true

require_relative "notion_file"

# Ruby → Notion builders for Sequel::Notion::TypeMap, split out here to
# keep type_map.rb's module short. See BUILDERS in type_map.rb for the
# Notion type => builder mapping that dispatches to these.

module Sequel
    module Notion
        module TypeMap
            # Float() also accepts hex ("0x1A"), binary ("0b11") and
            # underscore-grouped ("1_000") strings; a Notion number
            # property is plain decimal text only.
            DECIMAL = /\A\s*[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?\s*\z/

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
            rescue RangeError # a Complex has no Float
                raise Sequel::Error, "invalid number: #{value.inspect}"
            end

            # JSON has no NaN or Infinity
            def finite_number(value)
                return value if value.finite?

                raise Sequel::Error, "invalid number: #{value.inspect}"
            end

            # Float overflows "1e400" to Infinity instead of raising; it
            # also accepts hex/binary/underscored strings DECIMAL refuses
            def parse_number(value)
                raise Sequel::Error, "invalid number: #{value.inspect}" unless
                    value.match?(DECIMAL)

                finite_number(Float(value))
            rescue ArgumentError
                raise Sequel::Error, "invalid number: #{value.inspect}"
            end

            def build_select(value)
                return nil if value.nil?

                { "name" => value.to_s }
            end

            def build_multi_select(value)
                list(value).map { { "name" => it.to_s } }
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
            def build_relation(value) = list(value).map { { "id" => it } }

            def build_people(value)
                list(value).map { { "object" => "user", "id" => it } }
            end

            # One item or an Array of them; nil is none. Array() would
            # turn a Hash into its pairs.
            def list(value)
                if value.is_a?(Hash)
                    raise Sequel::Error, "a list of names or ids takes no " \
                                         "Hash: #{value.inspect}"
                end

                Array(value)
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
