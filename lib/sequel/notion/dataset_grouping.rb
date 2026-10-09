# frozen_string_literal: true

require "sequel/notion/dataset_having"
require "sequel/notion/filter_compiler"
require "sequel/notion/group_accumulator"

module Sequel
    module Notion
        # GROUP BY, which Notion's API does not compute: the rows the
        # query returns are read once, each group keeping one running
        # value per aggregate; ORDER, OFFSET and LIMIT then apply to the
        # groups. Empty values sort last, as in Notion.
        module DatasetGrouping
            include DatasetHaving

            private

            def grouped_rows(&)
                rows = sort_rows(groups).drop(@opts[:offset] || 0)
                rows = rows.take(@opts[:limit]) if @opts[:limit]
                rows.each(&)
            end

            # One row per group, HAVING applied, hidden outputs dropped
            def groups
                outs  = grouped_outputs
                funcs = having_functions
                rows  = group_rows(outs + having_outputs(funcs))
                rows  = rows.select { having?(it, funcs) } if @opts[:having]
                rows.map { it.slice(*outs.map(&:first)) }
            end

            def group_rows(outs)
                slots = group_slots(outs)
                accumulate(outs, slots).map do |key, accs|
                    grouped_row(outs, key, accs.each)
                end
            end

            def having_outputs(funcs)
                funcs.each_with_index.map do |func, i|
                    aggregate_output(func, having_name(i))
                end
            end

            def group_column(expr) = FilterCompiler.property_name(expr).to_sym

            # A column's identity: its table when qualified, and its name
            def column_key(expr)
                return [expr.table.to_s, expr.column.to_sym] if
                    expr.is_a?(SQL::QualifiedIdentifier)

                [nil, group_column(expr)]
            end

            def group_keys = @opts[:group].map { column_key(it) }

            # [name, :key, column] or [name, function, column (nil for *)]
            def grouped_outputs
                (@opts[:select] || @opts[:group]).map { group_output(it) }
            end

            def group_output(expr)
                name = expr.alias.to_sym if expr.is_a?(SQL::AliasedExpression)
                expr = expr.expression if name
                return aggregate_output(expr, name) if expr.is_a?(SQL::Function)

                key = column_key(expr)
                unless group_keys.include?(key)
                    raise Error, "#{key.last} is neither grouped nor aggregated"
                end

                [name || key.last, :key, expr]
            end

            def aggregate_output(func, name)
                function = func.name
                function = function.value if function.is_a?(SQL::Identifier)
                function = function.to_s.downcase.to_sym
                [name || function, function, aggregate_column(func, function)]
            end

            # The column aggregated, or nil for count(*)
            def aggregate_column(func, function)
                arg = func.args.first
                if plain_aggregate?(func, function)
                    return arg.tap { column_key(it) } unless star?(func)
                    return if function == :count
                end

                raise Error, "Unsupported aggregate: #{func.inspect}"
            end

            def star?(func)
                func.opts[:*] || func.args.empty? || func.args.first == "*"
            end

            def plain_aggregate?(func, function)
                GroupAccumulator::FUNCTIONS.include?(function) &&
                    func.args.size <= 1 && (func.opts.keys - [:*]).empty?
            end

            # column key => [column, hidden name it is read under]
            def group_slots(outs)
                columns = @opts[:group] + outs.filter_map(&:last)
                columns.uniq { column_key(it) }.each_with_index
                       .to_h { |col, i| [column_key(col), [col, :"__c#{i}"]] }
            end

            def accumulate(outs, slots)
                aggs  = outs.reject { it[1] == :key }
                names = group_keys.map { slots[it].last }
                group_source(slots).each_with_object({}) do |row, groups|
                    accs = groups[names.map { row[it] }] ||= accumulators(aggs)
                    add_row(row, aggs.zip(accs), slots)
                end
            end

            def accumulators(aggs) = aggs.map { GroupAccumulator.new(it[1]) }

            def add_row(row, pairs, slots)
                pairs.each do |(_, _, col), acc|
                    acc.add(col ? row[slots[column_key(col)].last] : 1)
                end
            end

            # The rows to group: the WHERE kept, Notion asked for nothing
            # else, and only the columns the groups need
            def group_source(slots)
                clone(group: nil, select: nil, order: nil, limit: nil,
                      offset: nil, distinct: nil, having: nil)
                    .naked.select(*slots.values.map { Sequel.as(*it) })
            end

            def grouped_row(outs, key, accs)
                keys = group_keys
                outs.to_h do |name, kind, col|
                    next [name, accs.next.value] unless kind == :key

                    [name, key[keys.index(column_key(col))]]
                end
            end
        end
    end
end
