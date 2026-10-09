# frozen_string_literal: true

require "sequel/notion/filter_compiler"

module Sequel
    module Notion
        module SortCompiler
            module_function

            def compile(order_clauses)
                Array(order_clauses).map { |clause| compile_one(clause) }
            end

            def compile_one(clause)
                case clause
                when Sequel::SQL::OrderedExpression then compile_ordered(clause)
                when Symbol, String, Sequel::SQL::Identifier,
                     Sequel::SQL::QualifiedIdentifier
                    compile_ascending(clause)
                else
                    raise Sequel::Error,
                          "Unsupported order expression: #{clause.class}"
                end
            end

            # Notion sorts empty values last in either direction, so only
            # NULLS LAST (or no NULLS clause) can be honoured
            def compile_ordered(clause)
                if clause.nulls == :first
                    raise Sequel::Error,
                          "Notion sorts empty values last: #{clause.inspect}"
                end

                direction = clause.descending ? "descending" : "ascending"
                { "property" => FilterCompiler.property_name(clause.expression),
                  "direction" => direction }
            end

            def compile_ascending(clause)
                { "property" => FilterCompiler.property_name(clause),
                  "direction" => "ascending" }
            end
        end
    end
end
