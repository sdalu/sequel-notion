# frozen_string_literal: true

module Sequel
    module Notion
        # UNION, INTERSECT and EXCEPT, which Notion's API does not
        # compute: each query's rows are read, then combined in Ruby as
        # SQL does (UNION ALL keeps repeats, the others drop them).
        # Sequel wraps the left query in a subquery; ORDER, OFFSET,
        # LIMIT and a SELECT of columns on the result apply to the
        # combined rows.
        module DatasetCompounds
            # Clauses the wrapping query cannot add to a combination
            OUTER_UNSUPPORTED = %i[where group having distinct join].freeze

            private

            # A subquery that combines nothing (from_self) is no compound,
            # and gets source_table's refusal
            def compound?
                from = @opts[:from]
                from&.size == 1 && from.first.is_a?(SQL::AliasedExpression) &&
                    from.first.expression.is_a?(Notion::Dataset) &&
                    !from.first.expression.opts[:compounds].nil?
            end

            def compound_inner = @opts[:from].first.expression

            def compound_rows
                bad = OUTER_UNSUPPORTED.select { @opts[it] }
                unless bad.empty?
                    raise Error, "a combined query takes no #{bad.join(", ")}"
                end

                sel  = compound_selection
                rows = sort_rows(combined_rows).drop(@opts[:offset] || 0)
                rows = rows.take(@opts[:limit]) if @opts[:limit]
                rows.each { yield project(it, sel) }
            end

            def compound_columns
                compound_selection&.map(&:last) || compound_inner.columns
            end

            # The outer SELECT, of columns the combined rows have
            def compound_selection
                sel = @opts[:select]
                return if sel.nil? || sel.empty?
                return if sel.any? { it == :* || it.is_a?(SQL::ColumnAll) }

                pairs   = sel.map { selected(it) }
                unknown = pairs.map(&:first) - compound_inner.columns
                return pairs if unknown.empty?

                raise Error, "Unknown columns in select: #{unknown.join(", ")}"
            end

            def combined_rows
                first = compound_inner.clone(compounds: nil)
                names = first.columns
                rows  = first.naked.all
                compound_inner.opts[:compounds].reduce(rows) do |left, step|
                    op, other, all = step
                    combined(op, left, renamed(other, names), all)
                end
            end

            # Another query's rows under the first query's column names,
            # matched by position, as SQL names a combination's columns
            def renamed(other, names)
                columns = other.columns
                unless columns.size == names.size
                    raise Error, "combined queries select #{names.size} " \
                                 "and #{columns.size} columns"
                end

                other.naked.all.map do |row|
                    names.zip(columns).to_h { |name, col| [name, row[col]] }
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
