# frozen_string_literal: true

require "sequel-notion/filter_compiler"

module Sequel
    module Notion
        # SELECT for Notion datasets: plain columns, optionally aliased
        module DatasetSelection
            private

            # [[source column, output name], ...], or nil for every column
            def selection
                sel = @opts[:select]
                return if sel.nil? || sel.empty?
                return if sel.any? { it == :* || it.is_a?(SQL::ColumnAll) }

                known!(sel.map { selected(it) })
            end

            def known!(pairs)
                unknown = pairs.map(&:first) -
                          db.schema(source_table).map(&:first)
                return pairs if unknown.empty?

                raise Error, "Unknown columns in select: #{unknown.join(", ")}"
            end

            def selected(expr)
                if expr.is_a?(SQL::AliasedExpression)
                    [column_name(expr.expression), expr.alias.to_sym]
                else
                    name = column_name(expr)
                    [name, name]
                end
            end

            def column_name(expr)
                FilterCompiler.property_name(expr).to_sym
            rescue Error
                raise Error, "Unsupported select expression: " \
                             "#{expr.inspect} (only columns can be selected)"
            end

            def project(row, sel)
                return row unless sel

                sel.to_h { |source, name| [name, row[source]] }
            end
        end
    end
end
