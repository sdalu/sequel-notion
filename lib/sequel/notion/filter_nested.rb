# frozen_string_literal: true

require "date"

module Sequel
    module Notion
        # Formula (rule F) and rollup (rule R) comparisons, mixed into
        # FilterCompiler: the condition nested under the kind of value
        # the property gives. All private.
        module FilterNested
            NESTED_KEYS = %w[formula rollup].freeze

            private

            def compile_nested_key(name, op, value, key)
                inner_key = if key == "formula"
                                formula_inner_key(value, name)
                            else
                                rollup_kind!(name)
                            end
                compile_nested_comparison(name, op, value, key, inner_key)
            end

            # IN on a formula, a rollup or a date: an or of equalities, or
            # an and of inequalities, each compiled as a comparison (nested,
            # or a date's before-or-after)
            def in_by_value(sequel_op, name, values, key)
                op = sequel_op == :IN ? :"=" : :"!="
                leaves = values.map do |v|
                    next null_check_filter(name, empty: op == :"=") if v.nil?

                    compile_typed_comparison(name, op, v, key)
                end
                { (sequel_op == :IN ? "or" : "and") => leaves }
            end

            # Notion checks a formula's emptiness under any value key,
            # whatever its result type (checked live); a rollup's under
            # the kind it gives
            def nested_null_filter(name, key, op)
                inner = key == "formula" ? "string" : rollup_kind!(name)
                { "property" => name, key => { inner => { op => true } } }
            end

            # A formula's kind follows the value's class
            def formula_inner_key(value, name)
                case value
                when String then "string"
                when Numeric then "number"
                when true, false then "checkbox"
                when Date, Time, DateTime then "date"
                else
                    raise Sequel::Error,
                          "Unsupported formula value type for property " \
                          "'#{name}': #{value.class}"
                end
            end

            def compile_formula_comparison(name, op, value)
                compile_nested_comparison(name, op, value, "formula",
                                          formula_inner_key(value, name))
            end

            def compile_nested_comparison(name, op, value, key, inner_key)
                coerced = coerce_value(value, inner_key)
                if inner_key == "date" && op == :"!="
                    return nested_date_not_equal(name, key, coerced)
                end

                notion_op = translated_operator(op, inner_key)
                ensure_supported!(name, inner_key, notion_op)
                { "property" => name,
                  key => { inner_key => { notion_op => coerced } } }
            end

            # A rollup whose function gives one value; one that keeps
            # every value is filtered by any/every/none in Notion, which a
            # SQL comparison does not say
            def rollup_kind!(name)
                kind = @rollups[name]
                return kind if %w[number date].include?(kind)

                raise Sequel::Error,
                      "Rollup '#{name}' gives #{kind || "an unknown"} " \
                      "values; only number and date rollups filter"
            end

            # Notion's date has no does_not_equal (rule D)
            def nested_date_not_equal(name, key, value)
                { "or" => %w[before after].map do |op|
                    { "property" => name, key => { "date" => { op => value } } }
                end }
            end
        end
    end
end
