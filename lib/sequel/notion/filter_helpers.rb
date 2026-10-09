# frozen_string_literal: true

require "date"

require "sequel/notion/filter_tables"
require "sequel/notion/type_map"

module Sequel
    module Notion
        # Small shared helpers mixed into FilterCompiler: property/type
        # lookups (rule N), column/literal recognition (rule S), and value
        # coercion. All private; they rely on the host's @prop_types.
        module FilterHelpers
            private

            # ----------------------------------------------------------
            # Shared lookups
            # ----------------------------------------------------------

            def lookup_type!(name)
                raise page_column_error(name) if
                    TypeMap::PAGE_KEYS.include?(name)

                @prop_types[name] or
                    raise Sequel::Error,
                          "Unknown property '#{name}'. " \
                          "Available: #{@prop_types.keys.join(", ")}"
            end

            # id and in_trash are the page's own, no property to filter on
            def page_column_error(name)
                hint = ": look pages up by id alone, where(id: ...)" if
                    name == "id"
                Sequel::Error.new("'#{name}' is the page's own column, " \
                                  "which Notion cannot filter on#{hint}")
            end

            def filter_key_for!(name, type)
                FilterTables::FILTER_TYPE_KEY[type] or
                    raise Sequel::Error,
                          "Property '#{name}' (type: #{type}) is not " \
                          "filterable"
            end

            def ensure_supported!(name, key, op)
                ops = FilterTables::SUPPORTED_OPS.fetch(key, [])
                return if ops.include?(op)

                why = " (never empty)" if key == "unique_id" && op =~ /empty/
                raise Sequel::Error, "Operator '#{op}' not supported for " \
                                     "#{key} property '#{name}'#{why}"
            end

            def equal_to_contains(op)
                case op
                when "equals" then "contains"
                when "does_not_equal" then "does_not_contain"
                else op
                end
            end

            # ----------------------------------------------------------
            # Column / literal helpers (rule S)
            # ----------------------------------------------------------

            def column_expr?(x)
                case x
                when Symbol, String, Sequel::SQL::Identifier,
                     Sequel::SQL::QualifiedIdentifier
                    true
                else
                    false
                end
            end

            def bare_column_expr?(x)
                x.is_a?(Symbol) ||
                    x.is_a?(Sequel::SQL::Identifier) ||
                    x.is_a?(Sequel::SQL::QualifiedIdentifier)
            end

            # Sequel wraps a bare literal in a NOOP NumericExpression when it
            # ends up as the receiver of a comparison operator inside a
            # virtual row block (e.g. `5 < n`). Unwrap it back to the plain
            # value.
            def unwrap_literal(value)
                if value.is_a?(Sequel::SQL::ComplexExpression) &&
                   value.op == :NOOP && value.args.length == 1
                    value.args.first
                else
                    value
                end
            end

            # ----------------------------------------------------------
            # Value coercion
            # ----------------------------------------------------------

            def boolean_value!(value)
                return value if [true, false].include?(value)

                raise Sequel::Error, "not a boolean: #{value.inspect}"
            end

            # Integer and Float as is; any other number as a Float, which
            # JSON writes as a number (BigDecimal and Rational would not).
            # JSON has no NaN or Infinity.
            def number_value!(value)
                number = case value
                         when Integer, Float then value
                         when Numeric then value.to_f
                         when String then decimal_number!(value)
                         else Float(value)
                         end
                return number if number.is_a?(Integer) || number.finite?

                raise Sequel::Error, "not a number: #{value.inspect}"
            rescue ArgumentError, TypeError, RangeError
                raise Sequel::Error, "not a number: #{value.inspect}"
            end

            # Float() also accepts hex/binary/underscored strings; a
            # number filter value is plain decimal text only
            def decimal_number!(value)
                raise Sequel::Error, "not a number: #{value.inspect}" unless
                    value.match?(TypeMap::DECIMAL)

                Float(value)
            end

            # A unique id's number, given bare or as displayed ("TK-62")
            def unique_id_value!(value)
                return value if value.is_a?(Integer) && !value.negative?

                number = value.to_s[/\A(?:[A-Za-z][\w-]*-)?(\d+)\z/, 1]
                return number.to_i if value.is_a?(String) && number

                raise Sequel::Error, "not a unique id: #{value.inspect}"
            end

            # A Date, Time or DateTime, or an ISO 8601 string
            def date_value!(value)
                return value.iso8601 if value.respond_to?(:iso8601)
                return value if value.is_a?(String) &&
                                !Date._iso8601(value).empty?

                raise Sequel::Error, "not a date: #{value.inspect}"
            end

            def coerce_value(value, key)
                case key
                when "date" then date_value!(value)
                when "checkbox" then boolean_value!(value)
                when "number" then number_value!(value)
                when "unique_id" then unique_id_value!(value)
                else
                    value.to_s
                end
            end
        end
    end
end
