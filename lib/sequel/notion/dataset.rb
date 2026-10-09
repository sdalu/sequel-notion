# frozen_string_literal: true

require "sequel/notion/dataset_pages"
require "sequel/notion/dataset_selection"
require "sequel/notion/type_map"

module Sequel
    module Notion
        class Dataset < Sequel::Dataset
            include DatasetPages
            include DatasetSelection

            def columns
                selection&.map(&:last) || db.schema(source_table).map(&:first)
            end

            def columns! = columns

            # Sequel renders SQL before fetching; there is none to render
            def select_sql = "NOTION #{source_table}"

            # Sequel's cached loaders swap WHERE for SQL placeholders,
            # which only a SQL database can fill in
            def supports_placeholder_literalizer? = false

            # Rows, auto-paginated, honouring LIMIT, OFFSET and SELECT
            def fetch_rows(sql)
                if @opts[:sql] || sql != select_sql
                    raise Error, "Notion datasets take no SQL"
                end

                sel = selection
                each_notion_page { yield project(TypeMap.page_to_row(it), sel) }
            end

            # Streams through Notion's cursor, as cursor adapters do: no
            # order needed, one request per page of rows_per_fetch (at
            # most 100). Sequel's :strategy, which pages by OFFSET or by
            # filtering on the order columns, does not apply.
            def paged_each(opts = OPTS, &)
                return enum_for(:paged_each, opts) unless block_given?

                size = opts[:rows_per_fetch]
                (size ? clone(notion_page_size: size) : self).each(&)
                self
            end

            def count(*args, &block)
                if !args.empty? || block
                    raise Error, "Notion datasets only count rows"
                end

                n = 0
                each_notion_page { n += 1 }
                n
            end

            def empty? = limit(1).first.nil?

            # ----------------------------------------------------------
            # Insert → create page
            # ----------------------------------------------------------

            def insert(*values)
                row = insert_hash(values).transform_keys(&:to_sym)
                row.delete(:id)
                if row.delete(:in_trash)
                    raise Error, "a page cannot be created in the trash"
                end

                db.notion_create_page(data_source_id, properties_for(row))["id"]
            end

            def import(columns, values, _opts = OPTS)
                values.map { insert(columns.zip(it).to_h) }
            end

            def multi_insert(hashes, _opts = OPTS) = hashes.map { insert(it) }

            # ----------------------------------------------------------
            # Update / delete — ids are collected first, so that pages
            # leaving the filter while being patched are not skipped
            # ----------------------------------------------------------

            def update(values = OPTS)
                raise Error, "update takes a Hash" unless values.is_a?(Hash)

                values = values.transform_keys(&:to_sym)
                in_trash = values.delete(:in_trash)
                values.delete(:id)
                props = properties_for(values)

                page_ids.each do |id|
                    db.notion_update_page(id, props, in_trash:)
                end.size
            end

            def delete
                page_ids.each { db.notion_trash_page(it) }.size
            end

            private

            def source_table
                from = @opts[:from]
                unless from&.size == 1 && from.first.is_a?(Symbol)
                    raise Error, "Notion datasets need a single table name"
                end

                from.first
            end

            def data_source_id
                db.data_source_id_for(source_table) or
                    raise Error, "Unknown data source: #{source_table}"
            end

            def properties_for(values)
                types = db.property_type_map(data_source_id)
                TypeMap.row_to_properties(values, types)
            end

            # Columns a positional insert fills, in schema order
            def writable
                db.schema(source_table)
                  .reject { |_, info| info[:generated] }
                  .map(&:first) - Schema::PAGE_COLUMNS.map(&:first)
            end

            def positional(vals)
                cols = writable
                if vals.size > cols.size
                    raise Error, "#{vals.size} values for #{cols.size} " \
                                 "writable columns"
                end

                cols.take(vals.size).zip(vals).to_h
            end

            def insert_hash(values)
                case values
                in [] then {}
                in [Hash => hash] then hash
                in [Array => cols, Array => vals] then cols.zip(vals).to_h
                in [Array => vals] then positional(vals)
                else raise Error, "Unsupported insert arguments"
                end
            end
        end
    end
end
