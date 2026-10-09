# frozen_string_literal: true

require "sequel/notion/errors"
require "sequel/notion/filter_compiler"
require "sequel/notion/sort_compiler"

module Sequel
    module Notion
        # Where a dataset's pages come from: a paginated data source
        # query, or a GET per page when WHERE pins the page id.
        module DatasetPages
            # Clauses Notion cannot express; refused rather than ignored
            UNSUPPORTED = %i[join group having distinct compounds lock].freeze

            PAGE_SIZE = 100

            private

            def page_ids
                ids = []
                each_notion_page { ids << it["id"] }
                ids
            end

            # Yield raw pages, after OFFSET and up to LIMIT
            def each_notion_page
                check_supported!
                skip = @opts[:offset] || 0
                max  = @opts[:limit]
                seen = 0
                source_pages do |page|
                    next if (skip -= 1) >= 0

                    yield page
                    break if max && (seen += 1) >= max
                end
            end

            def check_supported!
                bad = UNSUPPORTED.select { @opts[it] }
                return if bad.empty?

                raise Error, "Notion datasets do not support: " \
                             "#{bad.join(", ")}"
            end

            def source_pages(&)
                ds_id = data_source_id
                ids, rest = split_id_condition(@opts[:where])
                return pages_by_id(ds_id, ids, rest, &) if ids

                query_pages(ds_id, &)
            end

            def query_pages(ds_id)
                cursor = nil
                loop do
                    resp = db.notion_query(ds_id, query_body(ds_id, cursor))
                    (resp["results"] || []).each { yield it }
                    break unless resp["has_more"]

                    cursor = resp["next_cursor"]
                end
            end

            def query_body(ds_id, cursor)
                body = { page_size: notion_page_size }
                body[:filter] = filter(ds_id) if @opts[:where]
                body[:sorts]  = SortCompiler.compile(@opts[:order]) if
                    @opts[:order]
                body[:start_cursor] = cursor if cursor
                body
            end

            def filter(ds_id)
                FilterCompiler.for(db, ds_id).compile(@opts[:where])
            end

            def notion_page_size
                offset = @opts[:offset] || 0
                want   = @opts[:limit] && (@opts[:limit] + offset)
                [want || PAGE_SIZE, @opts[:notion_page_size] || PAGE_SIZE,
                 PAGE_SIZE].min
            end

            # ----------------------------------------------------------
            # Lookup by page id
            # ----------------------------------------------------------

            # [ids, other conditions] when WHERE pins the id, else nil
            def split_id_condition(where)
                return unless where.is_a?(SQL::BooleanExpression)
                return id_and_rest(where.args) if where.op == :AND

                ids = id_values(where)
                [ids, []] if ids
            end

            def id_and_rest(conds)
                sets = conds.filter_map { id_values(it) }
                return if sets.empty?

                [sets.reduce(:&), conds.reject { id_values(it) }]
            end

            def id_values(expr)
                return unless expr.is_a?(SQL::BooleanExpression)
                return unless %i[= IN].include?(expr.op)
                return unless FilterCompiler.property_name(expr.args[0]) ==
                              "id"

                Array(expr.args[1]).map { bare_id(it) }.uniq
            rescue Error
                nil
            end

            def pages_by_id(ds_id, ids, rest)
                unless rest.empty?
                    raise Error, "an id lookup cannot be combined with " \
                                 "other conditions"
                end

                ids.each do |id|
                    page = fetch_page(id)
                    yield page if page && in_source?(page, ds_id)
                end
            end

            # Trashed pages included: the row says so, and this is the
            # only way to reach one to restore it
            def fetch_page(id)
                db.notion_get_page(id)
            rescue NotFoundError
                nil
            end

            def in_source?(page, ds_id)
                parent = page["parent"] || {}
                parent["type"] == "data_source_id" &&
                    bare_id(parent["data_source_id"]) == bare_id(ds_id)
            end

            def bare_id(id) = id.to_s.delete("-").downcase
        end
    end
end
