# frozen_string_literal: true

require "sequel/notion/join_output"
require "sequel/notion/join_where"
require "sequel/notion/registry"

module Sequel
    module Notion
        # INNER and LEFT joins on one equality, which Notion's API does
        # not compute: each source is queried with the conditions that
        # test it alone, then rows are matched in Ruby. A relation (an
        # Array of page ids) matches every page it lists. Without a
        # SELECT, a later table's column wins a shared name, as with SQL
        # adapters.
        module DatasetJoins
            include JoinOutput
            include JoinWhere

            JOIN_TYPES = %i[inner left left_outer].freeze

            private

            def joined? = !@opts[:join].nil?

            def join_rows(&)
                sources = join_sources
                rows    = joined_rows(sources).map { join_output(it, sources) }
                rows    = sort_rows(rows).drop(@opts[:offset] || 0)
                rows    = rows.take(@opts[:limit]) if @opts[:limit]
                rows.each(&)
            end

            # { source name => row }, one per match
            def joined_rows(sources)
                wheres = split_where(sources)
                first  = sources.first
                rows   = source_rows(first, wheres)
                         .map { { first.first => it } }
                @opts[:join].each_with_index.reduce(rows) do |acc, (clause, i)|
                    joined(acc, clause, sources[i + 1], wheres)
                end
            end

            def join_sources
                [[source_table.to_s, source_table]] +
                    @opts[:join].map do |clause|
                        table = clause.table
                        table = table.value if table.is_a?(SQL::Identifier)
                        [(clause.table_alias || table).to_s, table.to_sym]
                    end
            end

            def source_rows((name, table), wheres)
                ds = db[table]
                Array(wheres[name]).each { ds = ds.where(it) }
                ds.naked.all
            end

            def joined(rows, clause, (name, table), wheres)
                left, right = join_columns(clause, name)
                if clause.join_type != :inner && wheres[name]
                    return left_joined(rows, left, right, [name, table],
                                       wheres)
                end

                index = join_index(source_rows([name, table], wheres), right)
                rows.flat_map { matched(it, left, index, clause, name) }
            end

            def join_index(rows, right)
                index = Hash.new { |h, k| h[k] = [] }
                rows.each do |row|
                    join_keys(row[right]).each { index[it] << row }
                end
                index
            end

            def matched(row, (table, column), index, clause, name)
                found = partners(row, table, column, index)
                return found.map { row.merge(name => it) } unless found.empty?

                clause.join_type == :inner ? [] : [row.merge(name => nil)]
            end

            def partners(row, table, column, index)
                join_keys(row[table]&.[](column)).flat_map { index[it] }.uniq
            end

            # [[left source, column], right column] of an ON a = b
            def join_columns(clause, name)
                args        = join_on!(clause).args
                right, left = args.partition { it.table.to_s == name }
                unless right.size == 1
                    raise Error, "a join's ON must test the joined table once"
                end

                [[left.first.table.to_s, left.first.column.to_sym],
                 right.first.column.to_sym]
            end

            def join_on!(clause)
                on = clause.on if clause.is_a?(SQL::JoinOnClause)
                return on if JOIN_TYPES.include?(clause.join_type) &&
                             equality?(on)

                raise Error, "Unsupported join: #{clause.inspect}"
            end

            def equality?(on)
                on.is_a?(SQL::BooleanExpression) && on.op == :"=" &&
                    on.args.all?(SQL::QualifiedIdentifier)
            end

            # A value's join keys: a relation's ids, page ids without
            # dashes and case
            def join_keys(value)
                Array(value).map do |v|
                    uuid = v.is_a?(String) && v.match?(Registry::UUID)
                    uuid ? v.delete("-").downcase : v
                end
            end
        end
    end
end
