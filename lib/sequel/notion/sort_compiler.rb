# frozen_string_literal: true

require "sequel/notion/filter_compiler"
require "sequel/notion/type_map"

module Sequel
    module Notion
        module SortCompiler
            module_function

            def compile(order_clauses)
                Array(order_clauses).map { |clause| compile_one(clause) }
            end

            def compile_one(clause)
                case clause
                when Sequel::LiteralString then raise literal_error(clause)
                when Sequel::SQL::OrderedExpression then compile_ordered(clause)
                when Symbol, String, Sequel::SQL::Identifier,
                     Sequel::SQL::QualifiedIdentifier
                    compile_ascending(clause)
                else
                    raise Sequel::Error,
                          "Unsupported order expression: #{clause.class}"
                end
            end

            # Sequel.lit is a String, but SQL, not a property name
            def literal_error(clause)
                Sequel::Error.new("Notion takes no SQL in an order: #{clause}")
            end

            # Notion sorts empty values last in either direction, so only
            # NULLS LAST (or no NULLS clause) can be honoured
            def compile_ordered(clause)
                if clause.nulls == :first
                    raise Sequel::Error,
                          "Notion sorts empty values last: #{clause.inspect}"
                end

                direction = clause.descending ? "descending" : "ascending"
                { "property" => sort_property(clause.expression),
                  "direction" => direction }
            end

            def compile_ascending(clause)
                { "property" => sort_property(clause),
                  "direction" => "ascending" }
            end

            # Notion sorts by a property or a timestamp, never by the
            # page's own id or in_trash, and rejects them with a 400
            def sort_property(expr)
                raise literal_error(expr) if expr.is_a?(Sequel::LiteralString)

                name = FilterCompiler.property_name(expr)
                return name unless TypeMap::PAGE_KEYS.include?(name)

                raise Sequel::Error, "Notion cannot sort by #{name}"
            end
        end
    end
end
