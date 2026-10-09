# frozen_string_literal: true

module Sequel
    module Notion
        # Rows Notion's API cannot compute (combined queries, groups,
        # DISTINCT), worked out in Ruby by DatasetCompounds,
        # DatasetGrouping and DatasetAggregates; ORDER over such rows is
        # sorted here, empty values last, as Notion sorts them.
        module DatasetComputed
            private

            # Rows Notion cannot compute, worked out in Ruby
            def computed? = compound? || @opts[:group] || @opts[:distinct]

            def computed_rows(&)
                return compound_rows(&) if compound?
                return grouped_rows(&) if @opts[:group]

                distinct_rows(&)
            end

            def computed_columns
                return compound_inner.columns if compound?

                grouped_outputs.map(&:first) if @opts[:group]
            end

            # ORDER over rows already computed (groups, combined rows)
            def sort_rows(rows)
                order = Array(@opts[:order]).map { grouped_order(it) }
                return rows if order.empty?

                rows.sort do |a, b|
                    order.lazy.map { |col, desc| compare(a[col], b[col], desc) }
                         .find(&:nonzero?) || 0
                end
            end

            def grouped_order(clause)
                if clause.is_a?(SQL::OrderedExpression)
                    return [group_column(clause.expression), clause.descending]
                end

                [group_column(clause), false]
            end

            def compare(left, right, desc)
                return (left.nil? ? 0 : -1) if right.nil?
                return 1 if left.nil?

                desc ? right <=> left : left <=> right
            end
        end
    end
end
