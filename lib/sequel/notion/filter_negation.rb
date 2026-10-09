# frozen_string_literal: true

require "sequel/notion/filter_tables"

module Sequel
    module Notion
        # Filter negation (rule G), mixed into FilterCompiler. All private.
        # Negates a compiled Notion filter hash by swapping and/or and
        # inverting the leaf operator via the explicit NEGATE_MAP table.
        module FilterNegation
            private

            def negate(filter)
                return opposite(filter) if constant?(filter)
                if filter.key?("and")
                    return { "or" => negate_each(filter["and"]) }
                end
                if filter.key?("or")
                    return { "and" => negate_each(filter["or"]) }
                end

                negate_leaf(filter)
            end

            def negate_each(filters)
                filters.map { negate(it) }
            end

            def negate_leaf(filter)
                type_key = (filter.keys - ["property"]).first
                inner = filter[type_key]

                if %w[formula rollup].include?(type_key)
                    negate_nested_leaf(filter, type_key, inner)
                else
                    negate_simple_leaf(filter, type_key, inner)
                end
            end

            def negate_nested_leaf(filter, key, inner)
                inner_key = inner.keys.first
                cond = inner[inner_key]
                op = cond.keys.first
                if inner_key == "date" && op == "equals"
                    return nested_date_not_equal(filter["property"], key,
                                                 cond[op])
                end

                new_op = negated_operator!(op, filter["property"])
                { "property" => filter["property"],
                  key => { inner_key => { new_op => cond[op] } } }
            end

            def negate_simple_leaf(filter, type_key, inner)
                op = inner.keys.first
                # Notion's date has no does_not_equal (rule D)
                if type_key == "date" && op == "equals"
                    return date_not_equal_filter(filter["property"], inner[op])
                end

                new_op = negated_operator!(op, filter["property"])

                { "property" => filter["property"],
                  type_key => { new_op => inner[op] } }
            end

            def negated_operator!(op, property)
                FilterTables::NEGATE_MAP.fetch(op) do
                    raise Sequel::Error,
                          "Operator '#{op}' has no inverse " \
                          "(property '#{property}')"
                end
            end
        end
    end
end
