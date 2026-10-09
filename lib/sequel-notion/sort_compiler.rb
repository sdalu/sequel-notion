# frozen_string_literal: true

module Sequel
  module Notion
    module SortCompiler
      module_function

      def compile(order_clauses)
        Array(order_clauses).map do |clause|
          case clause
          when Sequel::SQL::OrderedExpression
            {
              "property"  => clause.expression.to_s,
              "direction" => clause.descending ? "descending" : "ascending"
            }
          when Symbol, String
            { "property" => clause.to_s, "direction" => "ascending" }
          else
            raise Sequel::Error, "Unsupported order expression: #{clause.class}"
          end
        end
      end
    end
  end
end
