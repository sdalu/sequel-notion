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
        module JoinWhere
            private

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
