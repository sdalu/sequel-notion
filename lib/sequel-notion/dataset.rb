# frozen_string_literal: true

# frozen_string_literal: true

# frozen_string_literal: true

require "sequel-notion/filter_compiler"
require "sequel-notion/sort_compiler"

module Sequel
  module Notion
    class Dataset < Sequel::Dataset
      CLAUSE_METHODS = %i[select filter sort limit offset].freeze

      def columns
        all_cols = db.schema(first_source_table).map(&:first)

        if (sel = selected_columns)
          sel
        else
          all_cols
        end
      end

      # ----------------------------------------------------------
      # Fetching — auto-paginates, respects LIMIT and SELECT
      # ----------------------------------------------------------

      def fetch_rows(sql = nil, &block)
        ds_id = db.data_source_id_for(first_source_table)
        raise Error, "Unknown data source: #{first_source_table}" unless ds_id

        cursor  = nil
        yielded = 0
        max     = limit_value
        cols    = selected_columns

        loop do
          body = build_query_body(ds_id, start_cursor: cursor)
          resp = db.notion_query(ds_id, body)

          (resp["results"] || []).each do |page|
            break if max && yielded >= max

            row = TypeMap.page_to_row(page)
            row = filter_columns(row, cols) if cols
            yield row
            yielded += 1
          end

          break if max && yielded >= max
          break unless resp["has_more"]

          cursor = resp["next_cursor"]
        end
      end

      # ----------------------------------------------------------
      # Insert → create page
      # ----------------------------------------------------------

      def insert(*values)
        ds_id = db.data_source_id_for(first_source_table)
        props = TypeMap.row_to_properties(insert_arg_hash(values))
        resp  = db.notion_create_page(ds_id, props)
        resp["id"]
      end

      # ----------------------------------------------------------
      # Update → patch each matching page
      # ----------------------------------------------------------

      def update(values = OPTS)
        props   = TypeMap.row_to_properties(values)
        updated = 0

        each do |row|
          db.notion_update_page(row[:id], props)
          updated += 1
        end

        updated
      end

      # ----------------------------------------------------------
      # Delete → trash each matching page
      # ----------------------------------------------------------

      def delete
        deleted = 0

        each do |row|
          db.notion_trash_page(row[:id])
          deleted += 1
        end

        deleted
      end

      private

      # ----------------------------------------------------------
      # Column selection
      # ----------------------------------------------------------

      # Returns array of selected column symbols, or nil if select(:all)
      def selected_columns
        sel = @opts[:select]
        return nil if sel.nil? || sel.empty?

        # Sequel stores select as array of expressions
        cols = sel.map do |s|
          case s
          when Symbol                        then s
          when Sequel::SQL::AliasedExpression then s.expression.to_sym
          when Sequel::SQL::Identifier        then s.value.to_sym
          when Sequel::LiteralString          then s.to_sym
          else s.to_s.to_sym
          end
        end

        # :* means all columns
        return nil if cols.include?(:*)

        # Always include :id so update/delete can work
        cols.unshift(:id) unless cols.include?(:id)
        cols
      end

      # Keep only the requested columns in the row hash
      def filter_columns(row, cols)
        row.slice(*cols)
      end

      # ----------------------------------------------------------
      # Query body builder
      # ----------------------------------------------------------

      def build_query_body(ds_id, start_cursor: nil)
        body = { page_size: [limit_value || 100, 100].min }

        if (where = @opts[:where])
          prop_types = db.property_type_map(ds_id)
          compiler   = FilterCompiler.new(prop_types)
          body[:filter] = compiler.compile(where)
        end

        if (order = @opts[:order])
          body[:sorts] = SortCompiler.compile(order)
        end

        body[:start_cursor] = start_cursor if start_cursor
        body
      end

      def limit_value
        @opts[:limit]
      end

      def insert_arg_hash(values)
        case values.first
        when Hash  then values.first
        when Array then Hash[columns.zip(values.first)]
        else            raise Error, "Unsupported insert format"
        end
      end
    end
  end
end
