# frozen_string_literal: true

require "sequel/notion/filter_tables"

module Sequel
    module Notion
        # Predicate compilers mixed into FilterCompiler: emptiness checks,
        # IS / IS NOT, bare checkbox columns, and IN / NOT IN. All private.
        module FilterPredicates
            private

            # ----------------------------------------------------------
            # Null / empty check  ->  is_empty / is_not_empty
            # ----------------------------------------------------------
            #
            # Single method (dedupe rule) used both for `= nil` / `!= nil`
            # and for `IS nil` / `IS NOT nil`.
            def null_check_filter(name, empty:)
                type = lookup_type!(name)
                key = filter_key_for!(name, type)

                if key == "formula"
                    raise Sequel::Error,
                          "Cannot check emptiness of formula property " \
                          "'#{name}' (result type unknown)"
                end

                op = empty ? "is_empty" : "is_not_empty"
                ensure_supported!(name, key, op)

                { "property" => name, key => { op => true } }
            end

            # ----------------------------------------------------------
            # IS / IS NOT (rule I)
            # ----------------------------------------------------------

            def compile_is(expr)
                left, value = expr.args
                name    = FilterCompiler.property_name(left)
                negated = expr.op == :"IS NOT"

                case value
                when nil then null_check_filter(name, empty: !negated)
                when true, false then compile_is_boolean(name, negated, value)
                else
                    raise unsupported_is_value_error(name, value)
                end
            end

            def unsupported_is_value_error(name, value)
                Sequel::Error.new(
                    "Unsupported IS value for property '#{name}': " \
                    "#{value.inspect}"
                )
            end

            # A formula takes its boolean through the nested checkbox key
            def compile_is_boolean(name, negated, value)
                type = lookup_type!(name)
                key  = filter_key_for!(name, type)
                if key == "formula"
                    op = negated ? :"!=" : :"="
                    return compile_formula_comparison(name, op, value)
                end

                op = negated ? "does_not_equal" : "equals"
                op = equal_to_contains(op) if contains_type?(key)
                ensure_supported!(name, key, op)

                { "property" => name, key => { op => value } }
            end

            def contains_type?(key)
                FilterTables::CONTAINS_TYPES.include?(key)
            end

            # ----------------------------------------------------------
            # Bare column (rule B)
            # ----------------------------------------------------------

            def compile_bare_column(expr, value: true)
                name = FilterCompiler.property_name(expr)
                type = lookup_type!(name)
                key  = filter_key_for!(name, type)

                unless key == "checkbox"
                    raise Sequel::Error,
                          "Bare column '#{name}' must be a checkbox " \
                          "property, got type '#{type}'"
                end

                { "property" => name, "checkbox" => { "equals" => value } }
            end

            # ----------------------------------------------------------
            # IN / NOT IN (rule IN)
            # ----------------------------------------------------------

            def compile_in(expr)
                left, value = expr.args
                name = FilterCompiler.property_name(left)
                validate_in_array!(value, name)

                type = lookup_type!(name)
                key  = filter_key_for!(name, type)

                base_op = in_base_operator(expr.op, key)
                ensure_supported!(name, key, base_op)

                in_filter(expr.op, name, key, base_op, value)
            end

            def validate_in_array!(value, name)
                unless value.is_a?(Array)
                    raise Sequel::Error,
                          "IN/NOT IN requires an Array value for " \
                          "property '#{name}', got #{value.class}"
                end
                return unless value.empty?

                raise Sequel::Error,
                      "IN/NOT IN requires a non-empty Array value for " \
                      "property '#{name}'"
            end

            def in_base_operator(sequel_op, key)
                base_op = sequel_op == :IN ? "equals" : "does_not_equal"
                contains_type?(key) ? equal_to_contains(base_op) : base_op
            end

            def in_filter(sequel_op, name, key, base_op, value)
                leaves = value.map do |v|
                    { "property" => name,
                      key => { base_op => coerce_value(v, key) } }
                end

                { (sequel_op == :IN ? "or" : "and") => leaves }
            end
        end
    end
end
