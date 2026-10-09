# frozen_string_literal: true

module Sequel
    module Notion
        # UNION, INTERSECT and EXCEPT, which Notion's API does not
        # compute: each query's rows are read, then combined in Ruby as
        # SQL does (UNION ALL keeps repeats, the others drop them).
        # Sequel wraps the left query in a subquery; ORDER, OFFSET and
        # LIMIT on the result apply to the combined rows.
        module DatasetCompounds
            # Clauses the wrapping query cannot add to a combination
            OUTER_UNSUPPORTED = %i[where group having distinct join].freeze

            private

            def compound?
                from = @opts[:from]
                from&.size == 1 && from.first.is_a?(SQL::AliasedExpression) &&
                    from.first.expression.is_a?(Notion::Dataset)
            end

            def compound_inner = @opts[:from].first.expression

            def compound_rows(&)
                bad = OUTER_UNSUPPORTED.select { @opts[it] }
                unless bad.empty?
                    raise Error, "a combined query takes no #{bad.join(", ")}"
                end

                rows = sort_rows(combined_rows).drop(@opts[:offset] || 0)
                rows = rows.take(@opts[:limit]) if @opts[:limit]
                rows.each(&)
            end

            def combined_rows
                inner = compound_inner
                rows  = inner.clone(compounds: nil).naked.all
                inner.opts[:compounds].reduce(rows) do |left, (op, other, all)|
                    combined(op, left, other.naked.all, all)
                end
            end

            def combined(op, left, right, all)
                return all ? left + right : (left + right).uniq if op == :union
                raise Error, "#{op.upcase} ALL is not supported" if all

                op == :intersect ? left.uniq & right : left.uniq - right
            end
        end
    end
end
