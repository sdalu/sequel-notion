# frozen_string_literal: true

require "sequel/notion/filter_compiler"

module Sequel
    module Notion
        # Aggregates and DISTINCT, which Notion's API does not compute:
        # worked out in Ruby over the rows the query returns, so their
        # cost is that of reading every one. As in SQL, an aggregate skips
        # NULLs and is NULL over no value, and DISTINCT comes before
        # OFFSET and LIMIT.
        module DatasetAggregates
            AGGREGATES = {
                sum: ->(v) { v.sum unless v.empty? },
                avg: ->(v) { v.sum.fdiv(v.size) unless v.empty? },
                min: :min.to_proc,
                max: :max.to_proc
            }.freeze

            # Rows, or the non-NULL values of one column
            def count(*args, &block)
                if block || args.size > 1
                    raise Error, "Notion datasets count rows or one column"
                end

                args.empty? ? count_rows : column_values(args.first).size
            end

            private

            def count_rows
                return to_enum(:distinct_rows).count if @opts[:distinct]

                n = 0
                each_notion_page { n += 1 }
                n
            end

            # Sequel's sum, avg, min and max all land here
            def _aggregate(function, arg)
                AGGREGATES.fetch(function).call(column_values(arg))
            rescue TypeError, ArgumentError
                raise Error, "cannot compute #{function} of #{arg.inspect}"
            end

            def column_values(arg)
                column = FilterCompiler.property_name(arg).to_sym
                naked.select(column).map(column).compact
            end

            # Every row first, then OFFSET and LIMIT over the distinct ones
            def distinct_rows(&)
                all = clone(distinct: nil, limit: nil, offset: nil)
                rows = all.to_enum(:fetch_rows, all.select_sql).to_a.uniq
                rows = rows.drop(@opts[:offset] || 0)
                rows = rows.take(@opts[:limit]) if @opts[:limit]
                rows.each(&)
            end
        end
    end
end
