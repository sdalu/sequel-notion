# frozen_string_literal: true

require "sequel/notion/filter_compiler"

module Sequel
    module Notion
        # Which side of a join each column and each WHERE condition
        # belongs to, mixed into DatasetJoins. A source is
        # [name, table]: the alias, or the table's own name. An
        # unqualified column belongs to the one source whose schema has
        # it. A condition testing one source runs in Notion, on it; one
        # testing two has no Notion filter and raises.
        #
        # WHERE runs after the join. On an inner join, filtering a side
        # first gives the same rows; on a left join it does not, since a
        # row whose partner fails the condition would be kept with an
        # empty side. So a left join's own conditions filter its partners
        # after matching on the whole table, and a row with no partner is
        # kept only if an empty page passes them, as NULLs do in SQL.
        module JoinWhere
            private

            def left_joined(rows, left, right, source, wheres)
                name, = source
                index = join_index(source_rows(source, {}), right)
                kept  = source_rows(source, wheres).to_set { it[:id] }
                rows.flat_map do |row|
                    found = partners(row, *left, index)
                    next empty_side(row, source, wheres) if found.empty?

                    found.select { kept.include?(it[:id]) }
                         .map { row.merge(name => it) }
                end
            end

            def empty_side(row, (name, table), wheres)
                cond   = wheres[name].reduce(db[table]) { |ds, c| ds.where(c) }
                filter = FilterCompiler.for(db, db.data_source_id_for(table))
                                       .compile(cond.opts[:where])
                empty_match?(filter) ? [row.merge(name => nil)] : []
            end

            # Whether an empty page passes a compiled filter: only an
            # is_empty test does (negations carry is_not_empty)
            def empty_match?(filter)
                return filter["and"].all? { empty_match?(it) } if filter["and"]
                return filter["or"].any? { empty_match?(it) } if filter["or"]

                empty_test?(filter)
            end

            def empty_test?(value)
                value.is_a?(Hash) && (value.key?("is_empty") ||
                                      value.values.any? { empty_test?(it) })
            end

            # name => the conditions to send with that source's query
            def split_where(sources)
                conjuncts(@opts[:where]).group_by do |cond|
                    owners = referenced(cond, sources)
                    if owners.size > 1
                        raise Error, "a join's where tests one table per " \
                                     "condition: #{cond.inspect}"
                    end

                    owners.first || sources.first.first
                end
            end

            def conjuncts(expr)
                return [] if expr.nil?
                if expr.is_a?(SQL::BooleanExpression) && expr.op == :AND
                    return expr.args.flat_map { conjuncts(it) }
                end

                [expr]
            end

            def referenced(expr, sources)
                case expr
                when SQL::QualifiedIdentifier then [qualified(expr, sources)]
                when Symbol, SQL::Identifier then [owner(expr, sources)]
                when SQL::ComplexExpression then referenced(expr.args, sources)
                when Array then expr.flat_map { referenced(it, sources) }.uniq
                else []
                end
            end

            def qualified(expr, sources)
                name = expr.table.to_s
                return name if sources.any? { it.first == name }

                raise Error, "unknown table in a join: #{name}"
            end

            def owner(expr, sources)
                column = FilterCompiler.property_name(expr).to_sym
                found  = sources.select do |_, table|
                    db.schema(table).any? { it.first == column }
                end
                return found.first.first if found.one?

                raise Error, "column #{column} is in #{found.size} of the " \
                             "joined tables; qualify it"
            end
        end
    end
end
