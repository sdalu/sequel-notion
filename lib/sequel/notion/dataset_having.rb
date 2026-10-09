# frozen_string_literal: true

module Sequel
    module Notion
        # HAVING over the groups DatasetGrouping computes, evaluated in
        # Ruby with SQL's three-valued logic: a comparison with NULL is
        # unknown, and only a true condition keeps a group. An aggregate
        # it writes out (count(*) > 1) is computed as a hidden output.
        module DatasetHaving
            COMPARE = { "=": :==, "!=": :!=, "<": :<, ">": :>, "<=": :<=,
                        ">=": :>= }.freeze

            private

            def having_functions(expr = @opts[:having], found = [])
                case expr
                when SQL::Function
                    found << expr unless found.include?(expr)
                when SQL::ComplexExpression, Array
                    (expr.is_a?(Array) ? expr : expr.args)
                        .each { having_functions(it, found) }
                end
                found
            end

            def having_name(index) = :"__having_#{index}"

            def having?(row, funcs)
                having_value(@opts[:having], row, funcs) == true
            end

            def having_value(expr, row, funcs)
                case expr
                when SQL::Function then row[having_name(funcs.index(expr))]
                when SQL::BooleanExpression
                    having_boolean(expr, row, funcs)
                when Symbol, SQL::Identifier, SQL::QualifiedIdentifier
                    having_column(expr, row)
                when Array then expr.map { having_value(it, row, funcs) }
                else having_literal(expr, row, funcs)
                end
            end

            def having_literal(expr, row, funcs)
                return expr unless expr.is_a?(SQL::Expression)
                if expr.is_a?(SQL::ComplexExpression) && expr.op == :NOOP
                    return having_value(expr.args.first, row, funcs)
                end

                raise Error, "Unsupported HAVING expression: #{expr.inspect}"
            end

            def having_column(expr, row)
                name = group_column(expr)
                return row[name] if row.key?(name)

                raise Error,
                      "HAVING names #{name}, neither grouped nor selected"
            end

            def having_boolean(expr, row, funcs)
                values = expr.args.map { having_value(it, row, funcs) }
                case expr.op
                when :AND, :OR, :NOT then logical(expr.op, values)
                when :IS, :"IS NOT" then identity(expr.op, *values)
                when :IN, :"NOT IN" then in_list(expr.op, *values)
                else compared(expr.op, *values)
                end
            end

            def logical(op, values)
                return (values.first.nil? ? nil : !values.first) if op == :NOT

                decisive = op != :AND
                return decisive if values.include?(decisive)

                values.include?(nil) ? nil : !decisive
            end

            def identity(op, left, right)
                same = right.nil? ? left.nil? : left == right
                op == :IS ? same : !same
            end

            def in_list(op, left, list)
                found = list.include?(left) unless left.nil?
                found = nil if !found && (left.nil? || list.include?(nil))
                op == :IN || found.nil? ? found : !found
            end

            def compared(op, left, right)
                method = COMPARE.fetch(op) do
                    raise Error, "Unsupported HAVING operator: #{op}"
                end
                left.nil? || right.nil? ? nil : left.public_send(method, right)
            end
        end
    end
end
