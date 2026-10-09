# frozen_string_literal: true

require "sequel/notion/filter_compiler"

module Sequel
    module Notion
        # A joined row ({ source name => row }) as the row a query
        # returns, mixed into DatasetJoins: the selected columns, or every
        # column with a later table winning a shared name.
        module JoinOutput
            private

            def join_output(row, sources)
                sel = @opts[:select]
                return merged_row(row, sources) if sel.nil? || sel.empty?

                sel.to_h { join_selected(it, row, sources) }
            end

            def merged_row(row, sources)
                sources.each_with_object({}) do |(name, table), out|
                    out.merge!(row[name] || null_row(table))
                end
            end

            def null_row(table) = db.schema(table).to_h { [it.first, nil] }

            def join_selected(expr, row, sources)
                name = expr.alias.to_sym if expr.is_a?(SQL::AliasedExpression)
                expr = expr.expression if name
                source, column = join_column(expr, sources)
                [name || column, row[source]&.[](column)]
            end

            def join_column(expr, sources)
                case expr
                when SQL::QualifiedIdentifier
                    [qualified(expr, sources), expr.column.to_sym]
                when Symbol, SQL::Identifier
                    [owner(expr, sources),
                     FilterCompiler.property_name(expr).to_sym]
                else
                    raise Error, "only columns can be selected from a " \
                                 "join: #{expr.inspect}"
                end
            end

            def join_columns_out(sources)
                sel = @opts[:select]
                return sel.map { join_selected(it, {}, sources).first } if
                    sel && !sel.empty?

                sources.flat_map { |_, table| db.schema(table).map(&:first) }
                       .uniq
            end
        end
    end
end
