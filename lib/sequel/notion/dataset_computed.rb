# frozen_string_literal: true

module Sequel
    module Notion
        # Rows Notion's API cannot compute (combined queries, groups,
        # DISTINCT, joins), worked out in Ruby by DatasetCompounds,
        # DatasetGrouping, DatasetAggregates and DatasetJoins; ORDER over
        # such rows is sorted here, empty values last, as Notion sorts
        # them. Such a query reads every row it matches, so it runs only
        # on a dataset that opts in with client_side; otherwise it raises
        # before the first request.
        module DatasetComputed
            # Allow what Notion cannot compute to be computed in Ruby;
            # max_requests caps the Notion requests each query may send
            def client_side(max_requests: nil)
                clone(client_side: true, max_requests:)
            end

            private

            # Sequel wraps the left query of a UNION, which keeps the opt-in
            def client_side?
                @opts[:client_side] ||
                    (compound? && compound_inner.opts[:client_side])
            end

            def client_side!(what)
                return if client_side?

                raise Error, "#{what} is computed in Ruby over every row " \
                             "the query returns; call client_side on the " \
                             "dataset to allow it"
            end

            def computed_operation
                compounds = compound_inner.opts[:compounds] if compound?
                return compounds.first.first.upcase.to_s if compounds
                return "GROUP BY" if @opts[:group]
                return "DISTINCT" if @opts[:distinct]

                "JOIN"
            end

            # Rows Notion cannot compute, worked out in Ruby
            def computed?
                compound? || @opts[:group] || @opts[:distinct] || joined?
            end

            # Groups and DISTINCT over joined rows: the join comes last
            def computed_rows(&)
                raise Error, "Notion datasets do not support: lock" if
                    @opts[:lock]

                client_side!(computed_operation)
                return compound_rows(&) if compound?
                return grouped_rows(&) if @opts[:group]
                return distinct_rows(&) if @opts[:distinct]

                join_rows(&)
            end

            def computed_columns
                return compound_inner.columns if compound?
                return grouped_outputs.map(&:first) if @opts[:group]

                join_columns_out(join_sources) if joined?
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
