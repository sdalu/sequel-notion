# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "sequel"
require "sequel-notion/dataset"
require "sequel-notion/schema"
require "sequel-notion/type_map"

module Sequel
module Notion
    API_BASE    = "https://api.notion.com/v1"
    API_VERSION = "2026-03-11"

    class Database < Sequel::Database
        set_adapter_scheme :notion


        # ----------------------------------------------------------
        # Connection — a shared Faraday instance
        # ----------------------------------------------------------

        def connect(_server)
            token = opts[:token]
            raise Error, 'Missing Notion token' unless token

            Faraday.new(url: API_BASE) do |f|
                f.headers['Authorization']  = "Bearer #{token}"
                f.headers['Notion-Version'] = API_VERSION
                f.headers['Content-Type']   = 'application/json'

                f.request  :retry, max: 3,
                                   interval: 0.5,
                                   backoff_factor: 2,
                                   retry_statuses: [429, 502, 503, 504]
                f.response :raise_error
                f.response :json, content_type: /\bjson$/
                f.adapter  Faraday.default_adapter
            end
        end

        def connection
            @connection ||= connect(nil)
        end

        def disconnect_connection(_conn) = nil

        def dataset_class_default = Notion::Dataset


        # ----------------------------------------------------------
        # Data source registry
        # ----------------------------------------------------------

        def register_data_source(name, datasource = nil, database: nil, query: nil)
            @data_sources ||= {}
            @data_sources[name.to_sym] = datasource
            self
        end

        def register_all_data_sources(database: nil, query: nil, &mapper)
            @data_sources ||= {}
            data_sources(database:, query:).each do |ds| pp ds.inspect
                name = if mapper
                           mapper.(ds[:name], ds[:id])
                       else

                           (ds[:name] || ds[:id]).downcase
                                                 .gsub(/[^a-z0-9]+/, "_")
                                                 .gsub(/\A_|_\z/, "")
                       end
                @data_sources.merge!(name.to_sym => ds[:id]) do |k,o,n|
                    o.tap {
                        if o != n
                            raise Error, "trying to add different source with the same name (#{k} => #{o} vs #{n})"
                        end
                    }
                end
            end

        end

        def data_source_id_for(table_name)
            @data_sources ||= {}

            # Try explicit registry first
            return @data_sources[table_name.to_sym] if @data_sources.key?(table_name.to_sym)

            # Lazy auto-register all sources on first miss
            if opts[:auto_register] && !@auto_registered
                @auto_registered = true
                register_all_data_sources
                return @data_sources[table_name.to_sym] if @data_sources.key?(table_name.to_sym)
            end

            # Fallback: single name lookup
            (data_sources(query: table_name.to_s).find do |ds|
                ds[:name]&.downcase == table_name.to_s.downcase
            end)&.dig(:id)
        end


        # ----------------------------------------------------------
        # Schema introspection
        # ----------------------------------------------------------

        def schema(table, _opts = OPTS)
            ds_id = data_source_id_for(table)
            raise Error, "Unknown data source: #{table}" unless ds_id

            resp  = connection.get("data_sources/#{ds_id}").body
            props = resp['properties'] || {}

            Schema.notion_to_sequel(props)
        end

        def tables
            @data_sources ||= {}

            # Force discovery if auto_register is on
            if opts[:auto_register] && !@auto_registered
                @auto_registered = true
                register_all_data_sources
            end

            @data_sources.keys
        end

        # List all data sources
        def data_sources(database: nil, query: nil)
            if database && query
                raise ArgumentError, "database and query can't be both specified"
            end

            sources = []

            if database
                resp = connection.get("databases/#{database}").body
                (resp['data_sources'] || []).map do |ds|
                    ds.slice('id', 'name', 'icon', 'url', 'in_trash', 'properties')
                        .transform_keys(&:to_sym)
                        .merge(parent_database_id: database)
                end
            else
                cursor  = nil
                loop do
                    params = {
                        page_size: 100,
                        filter: { property: 'object', value: 'data_source' }
                    }
                    params[:sort        ] =  { direction: 'descending',
                                               timestamp: 'last_edited_time' }
                    params[:query       ] = query  if query
                    params[:start_cursor] = cursor if cursor

                    resp = connection.post('search', params.to_json).body

                    sources += (resp['results'] || [])
                        .select {|ds| ds['object'] == 'data_source' }
                        .map    {|ds|
                          ds.slice('id', 'icon', 'url', 'in_trash', 'properties')
                            .transform_keys(&:to_sym)
                              .merge(parent_database_id:  ds.dig('parent', 'database_id'))
                              .merge(:name => ds['title']&.map { it['plain_text'] }&.join)
                        }

                    break unless resp['has_more']
                    cursor = resp['next_cursor']
                end

                sources
            end

        end

        # ----------------------------------------------------------
        # Property type map cache (mutable — safe on Database)
        # ----------------------------------------------------------

        def property_type_map(ds_id)
            @property_type_cache ||= {}
            @property_type_cache[ds_id] ||=
                begin
                    resp  = connection.get("data_sources/#{ds_id}").body
                    props = resp['properties'] || {}
                    props.transform_values { |v| v['type'] }
                end
        end

        def refresh_schema!(table_name)
            ds_id = data_source_id_for(table_name)
            @property_type_cache&.delete(ds_id)
        end

        # ----------------------------------------------------------
        # Raw API access (used by Dataset)
        # ----------------------------------------------------------

        def notion_query(data_source_id, body)
            connection.post(
                "data_sources/#{data_source_id}/query",
                body.to_json
            ).body
        end

        def notion_create_page(data_source_id, properties)
            connection.post("pages", {
                                parent:     { type: "data_source", data_source_id: data_source_id },
                                properties: properties
                            }.to_json).body
        end

        def notion_update_page(page_id, properties)
            connection.patch("pages/#{page_id}", {
                                 properties: properties
                             }.to_json).body
        end

        def notion_trash_page(page_id)
            connection.patch("pages/#{page_id}", {
                                 in_trash: true
                             }.to_json).body
        end


    end
end
end
