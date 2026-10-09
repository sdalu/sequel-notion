# frozen_string_literal: true

require "date"
require "sequel/notion/filter_tables"

module Sequel
    module Notion
        # Standard and date-inequality (rule D) comparison compilation,
        # mixed into FilterCompiler; formulas and rollups are FilterNested's.
        # All private.
        module FilterComparison
            private

            # ----------------------------------------------------------
            # Standard comparison
            # ----------------------------------------------------------

            def compile_comparison(expr)
                case expr.op
                when :IN, :"NOT IN" then return compile_in(expr)
                when :LIKE, :ILIKE, :"NOT LIKE", :"NOT ILIKE"
                    return compile_like(expr)
                end

                name, op, value = comparison_operands(expr)
                return null_comparison_filter(name, op) if value.nil?

                type = lookup_type!(name)
                key  = filter_key_for!(name, type)

                compile_typed_comparison(name, op, value, key)
            end

            # Swaps a comparison's operands into column-then-value order
            # (rule S): a < b  ==  b > a
            def comparison_operands(expr)
                op = expr.op
                left, right = expr.args

                if !column_expr?(left) && column_expr?(right)
                    left, right = right, left
                    op = mirrored_operator(op)
                end

                [FilterCompiler.property_name(left), op,
                 literal_value!(unwrap_literal(right))]
            end

            # Notion compares a property with a value, never with another
            # property or an expression
            def literal_value!(value)
                return value unless bare_column_expr?(value) ||
                                    value.is_a?(Sequel::SQL::Expression)

                raise Sequel::Error,
                      "Notion filters compare with values only: " \
                      "#{value.inspect}"
            end

            def mirrored_operator(op)
                FilterTables::MIRROR_OPERATOR.fetch(op) do
                    raise Sequel::Error, "Unsupported operator: #{op}"
                end
            end

            def null_comparison_filter(name, op)
                case op
                when :"=" then null_check_filter(name, empty: true)
                when :"!=" then null_check_filter(name, empty: false)
                else
                    raise Sequel::Error,
                          "Unsupported nil comparison operator: #{op}"
                end
            end

            def compile_typed_comparison(name, op, value, key)
                if FilterNested::NESTED_KEYS.include?(key)
                    return compile_nested_key(name, op, value, key)
                end
                if key == "date" && op == :"!="
                    return date_not_equal_filter(name, value)
                end

                notion_op = translated_operator(op, key)
                ensure_supported!(name, key, notion_op)

                { "property" => name,
                  key => { notion_op => coerce_value(value, key) } }
            end

            # Looks up the Notion operator for `op`, remapping it for date
            # properties and for the types that express (not)equal through
            # contains/does_not_contain (rule IN).
            def translated_operator(op, key)
                notion_op = FilterTables::OPERATOR_MAP.fetch(op) do
                    raise Sequel::Error, "Unsupported operator: #{op}"
                end
                if key == "date"
                    notion_op = FilterTables::DATE_OPERATOR_MAP.fetch(
                        notion_op, notion_op
                    )
                end
                contains_type?(key) ? equal_to_contains(notion_op) : notion_op
            end

            # ----------------------------------------------------------
            # Date inequality (rule D)
            # ----------------------------------------------------------

            def date_not_equal_filter(name, value)
                coerced = coerce_value(value, "date")
                {
                    "or" => [
                        { "property" => name,
                          "date" => { "before" => coerced } },
                        { "property" => name,
                          "date" => { "after" => coerced } }
                    ]
                }
            end
        end
    end
end
