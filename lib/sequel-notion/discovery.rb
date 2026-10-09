# frozen_string_literal: true

module Sequel
    module Notion
        # Listing the data sources the integration can see
        module Discovery
            # List data sources: those of one database, or a search
            def data_sources(database: nil, query: nil)
                if database && query
                    raise ArgumentError, "database and query are exclusive"
                end

                database ? database_sources(database) : search_sources(query)
            end

            private

            def database_sources(database)
                resp = request(:get, "databases/#{database}")
                (resp["data_sources"] || []).map do |ds|
                    ds.slice("id", "name").transform_keys(&:to_sym)
                      .merge(parent_database_id: database)
                end
            end

            def search_sources(query)
                sources = []
                cursor  = nil
                loop do
                    resp = request(:post, "search", search_body(query, cursor))
                    sources.concat(source_entries(resp["results"]))
                    break unless resp["has_more"]

                    cursor = resp["next_cursor"]
                end
                sources
            end

            def source_entries(results)
                (results || []).filter_map do |entry|
                    source_entry(entry) if entry["object"] == "data_source"
                end
            end

            def search_body(query, cursor)
                body = { page_size: 100,
                         filter: { property: "object", value: "data_source" },
                         sort: { direction: "descending",
                                 timestamp: "last_edited_time" } }
                body[:query]        = query  if query
                body[:start_cursor] = cursor if cursor
                body
            end

            def source_entry(ds)
                ds.slice("id", "icon", "url", "in_trash", "properties")
                  .transform_keys(&:to_sym)
                  .merge(parent_database_id: ds.dig("parent", "database_id"),
                         name: ds["title"]&.map { it["plain_text"] }&.join)
            end
        end
    end
end
