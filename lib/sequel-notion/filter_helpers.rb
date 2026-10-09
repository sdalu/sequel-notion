# frozen_string_literal: true

require "sequel-notion/filter_tables"

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
                @prop_types[name] or
                    raise Sequel::Error,
                          "Unknown property '#{name}'. " \
                          "Available: #{@prop_types.keys.join(", ")}"
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

                raise Sequel::Error,
                      "Operator '#{op}' not supported for " \
                      "#{key} property '#{name}'"
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
            # JSON writes as a number (BigDecimal and Rational would not)
            def number_value!(value)
                case value
                when Integer, Float then value
                when Numeric then value.to_f
                else Float(value)
                end
            rescue ArgumentError, TypeError
                raise Sequel::Error, "not a number: #{value.inspect}"
            end

            def coerce_value(value, key)
                case key
                when "date"
                    value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
                when "checkbox" then boolean_value!(value)
                when "number" then number_value!(value)
                else
                    value.to_s
                end
            end
        end
    end
end
