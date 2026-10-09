# frozen_string_literal: true

require "sequel/notion/filter_compiler"
require "sequel/notion/group_accumulator"

module Sequel
    module Notion
        # GROUP BY, which Notion's API does not compute: the rows the
        # query returns are read once, each group keeping one running
        # value per aggregate; ORDER, OFFSET and LIMIT then apply to the
        # groups. Empty values sort last, as in Notion.
        module DatasetGrouping
            private

            def grouped_rows(&)
                keys = grouped_keys
                outs = grouped_outputs
                rows = accumulate(keys, outs).map do |key, accs|
                    grouped_row(keys, outs, key, accs.each)
                end
                rows = sort_grouped(rows).drop(@opts[:offset] || 0)
                rows = rows.take(@opts[:limit]) if @opts[:limit]
                rows.each(&)
            end

            def grouped_keys = @opts[:group].map { group_column(it) }

            def group_column(expr) = FilterCompiler.property_name(expr).to_sym

            # [name, :key, column] or [name, function, column (nil for *)]
            def grouped_outputs
                keys = grouped_keys
                (@opts[:select] || keys).map { group_output(it, keys) }
            end

            def group_output(expr, keys)
                name = expr.alias.to_sym if expr.is_a?(SQL::AliasedExpression)
                expr = expr.expression if name
                return aggregate_output(expr, name) if expr.is_a?(SQL::Function)

                column = group_column(expr)
                unless keys.include?(column)
                    raise Error, "#{column} is neither grouped nor aggregated"
                end

                [name || column, :key, column]
            end

            def aggregate_output(func, name)
                function = func.name.to_s.downcase.to_sym
                [name || function, function, aggregate_column(func, function)]
            end

            # The column aggregated, or nil for count(*)
            def aggregate_column(func, function)
                arg = func.args.first
                if plain_aggregate?(func, function)
                    return group_column(arg) unless arg.nil? || arg == "*"
                    return if function == :count
                end

                raise Error, "Unsupported aggregate: #{func.inspect}"
            end

            def plain_aggregate?(func, function)
                GroupAccumulator::FUNCTIONS.include?(function) &&
                    func.args.size <= 1 && func.opts.empty?
            end

            def accumulate(keys, outs)
                aggs   = outs.reject { it[1] == :key }
                groups = {}
                group_source(keys, aggs).each do |row|
                    accs = groups[keys.map { row[it] }] ||=
                        aggs.map { GroupAccumulator.new(it[1]) }
                    aggs.each_with_index do |(_, _, col), i|
                        accs[i].add(col ? row[col] : 1)
                    end
                end
                groups
            end

            # The rows to group: the WHERE kept, Notion asked for nothing
            # else, and only the columns the groups need
            def group_source(keys, aggs)
                cols = (keys + aggs.filter_map(&:last)).uniq
                clone(group: nil, select: nil, order: nil, limit: nil,
                      offset: nil, distinct: nil).naked.select(*cols)
            end

            def grouped_row(keys, outs, key, accs)
                # an output is a group key, or the next aggregate's value
                outs.to_h do |name, kind, col|
                    [name,
                     kind == :key ? key[keys.index(col)] : accs.next.value]
                end
            end

            def sort_grouped(rows)
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
