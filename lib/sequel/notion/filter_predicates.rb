# frozen_string_literal: true

require "sequel/notion/filter_nested"
require "sequel/notion/filter_tables"

module Sequel
    module Notion
        # Predicate compilers mixed into FilterCompiler: emptiness checks,
        # IS / IS NOT, bare checkbox columns, and IN / NOT IN. All private.
        module FilterPredicates
            # Keys whose IN goes value by value: nested, or a date, which
            # has no does_not_equal
            IN_BY_VALUE = (FilterNested::NESTED_KEYS + ["date"]).freeze

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

                op = empty ? "is_empty" : "is_not_empty"
                return nested_null_filter(name, key, op) if
                    FilterNested::NESTED_KEYS.include?(key)

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

            # A checkbox, or a formula through its nested checkbox key, as
            # for a bare column
            def compile_is_boolean(name, negated, value)
                type = lookup_type!(name)
                case filter_key_for!(name, type)
                when "checkbox"
                    op = negated ? "does_not_equal" : "equals"
                    { "property" => name, "checkbox" => { op => value } }
                when "formula"
                    op = negated ? :"!=" : :"="
                    compile_formula_comparison(name, op, value)
                else raise boolean_type_error(name, type, value)
                end
            end

            def boolean_type_error(name, type, value)
                Sequel::Error.new("'#{name}' IS #{value}: a checkbox or " \
                                  "formula property only, got type '#{type}'")
            end

            def contains_type?(key)
                FilterTables::CONTAINS_TYPES.include?(key)
            end

            # ----------------------------------------------------------
            # Bare column (rule B)
            # ----------------------------------------------------------

            # A checkbox, or a formula through its checkbox key
            def compile_bare_column(expr, value: true)
                name = FilterCompiler.property_name(expr)
                type = lookup_type!(name)
                case filter_key_for!(name, type)
                when "checkbox"
                    { "property" => name, "checkbox" => { "equals" => value } }
                when "formula"
                    compile_formula_comparison(name, :"=", value)
                else raise bare_column_error(name, type)
                end
            end

            def bare_column_error(name, type)
                Sequel::Error.new("Bare column '#{name}' must be a checkbox " \
                                  "or formula property, got type '#{type}'")
            end

            # ----------------------------------------------------------
            # IN / NOT IN (rule IN)
            # ----------------------------------------------------------

            def compile_in(expr)
                left, value = expr.args
                name = FilterCompiler.property_name(left)
                validate_in_array!(value, name)

                key = filter_key_for!(name, lookup_type!(name))
                return empty_in(expr.op) if value.empty?
                return in_by_value(expr.op, name, value, key) if
                    IN_BY_VALUE.include?(key)

                base_op = in_base_operator(expr.op, key)
                ensure_supported!(name, key, base_op)

                in_filter(expr.op, name, key, base_op, value)
            end

            def validate_in_array!(value, name)
                return if value.is_a?(Array)

                raise Sequel::Error,
                      "IN/NOT IN requires an Array value for " \
                      "property '#{name}', got #{value.class}"
            end

            # IN () matches no page, NOT IN () every page
            def empty_in(sequel_op)
                return FilterConstants::NOTHING if sequel_op == :IN

                FilterConstants::EVERYTHING
            end

            def in_base_operator(sequel_op, key)
                base_op = sequel_op == :IN ? "equals" : "does_not_equal"
                contains_type?(key) ? equal_to_contains(base_op) : base_op
            end

            # A nil in the list means empty, as `where(P: nil)` does
            def in_filter(sequel_op, name, key, base_op, value)
                leaves = value.map do |v|
                    next null_check_filter(name, empty: sequel_op == :IN) if
                        v.nil?

                    { "property" => name,
                      key => { base_op => coerce_value(v, key) } }
                end

                { (sequel_op == :IN ? "or" : "and") => leaves }
            end
        end
    end
end
