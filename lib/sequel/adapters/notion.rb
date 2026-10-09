# frozen_string_literal: true

require "json"

require "faraday"
require "faraday/retry"
require "sequel"

require "sequel-notion/dataset"
require "sequel-notion/errors"
require "sequel-notion/model_support"
require "sequel-notion/page_api"
require "sequel-notion/registry"
require "sequel-notion/schema"
require "sequel-notion/type_map"
require "sequel-notion/version"

module Sequel
    module Notion
        API_BASE    = "https://api.notion.com/v1"
        API_VERSION = "2026-03-11"

        # Statuses worth another attempt; 429 carries Retry-After, which
        # faraday-retry honours.
        RETRY_STATUSES = [429, 502, 503, 504].freeze

        # Creating a page is the one call a retry could duplicate: retry it
        # only when Notion refused it outright (rate limited).
        RETRY_IF = lambda do |env, _exception|
            !(env.method == :post && env.url.path.end_with?("/pages")) ||
                env.status == 429
        end

        class Database < Sequel::Database
            include PageApi
            include Registry

            set_adapter_scheme :notion

            def initialize(...)
                super
                @data_source_cache = {}
            end

            # ----------------------------------------------------------
            # Connection — one Faraday client per pooled connection
            # ----------------------------------------------------------

            def connect(_server)
                token = opts[:token]
                raise Error, "Missing Notion token" unless token

                Faraday.new(url: API_BASE) { build_stack(it, token) }
            end

            def disconnect_connection(_conn) = nil

            def dataset_class_default = Notion::Dataset

            # Notion has no transactions: run the block as is, so that
            # Sequel::Model (which wraps saves in one) works.
            def transaction(_opts = OPTS)
                synchronize { yield it }
            rescue Rollback
                nil
            end

            def table_exists?(name)
                ds_id = data_source_id_for(name)
                !ds_id.nil? && !data_source(ds_id).nil?
            rescue NotFoundError
                false
            end

            def in_transaction?(_opts = OPTS) = false

            def supports_savepoints?            = false
            def supports_schema_parsing?        = true
            def supports_transaction_isolation_levels? = false

            # ----------------------------------------------------------
            # Schema introspection
            # ----------------------------------------------------------

            # Property name => Notion type, for one data source
            def property_type_map(ds_id)
                data_source(ds_id).transform_values { it["type"] }
            end

            def refresh_schema!(table_name)
                ds_id = data_source_id_for(table_name)
                Sequel.synchronize { @data_source_cache.delete(ds_id) }
                remove_cached_schema(table_name)
            end

            # One Notion request: logged through Sequel's loggers, and any
            # HTTP failure re-raised as a Sequel::DatabaseError.
            def request(verb, path, body = nil)
                synchronize do |conn|
                    log_connection_yield("#{verb.upcase} #{path}", conn,
                                         body && [body]) do
                        conn.public_send(verb, path, body).body
                    end
                end
            rescue Faraday::Error => e
                raise database_error(e)
            end

            private

            def build_stack(conn, token)
                conn.headers["Authorization"]  = "Bearer #{token}"
                conn.headers["Notion-Version"] = API_VERSION
                conn.request :json
                # raise_error must wrap retry, so retry sees the raw
                # status before it is turned into an exception.
                conn.response :raise_error
                conn.request  :retry, retry_options
                conn.response :json, content_type: /\bjson$/
                conn.adapter(*Array(opts[:faraday_adapter] ||
                                    Faraday.default_adapter))
            end

            def retry_options
                { max: 4,
                  interval: 0.5,
                  backoff_factor: 2,
                  methods: %i[get patch delete],
                  retry_if: RETRY_IF,
                  retry_statuses: RETRY_STATUSES }
            end

            def database_error(error)
                body   = error.response_body
                status = error.response_status
                detail = if body.is_a?(Hash)
                             "#{body["code"]}: #{body["message"]}"
                         else
                             error.message
                         end
                klass  = status == 404 ? NotFoundError : DatabaseError
                klass.new("Notion #{status || "request"} #{detail}")
                     .tap { it.wrapped_exception = error }
            end

            # Data source object properties, fetched once and cached
            def data_source(ds_id)
                cached = Sequel.synchronize { @data_source_cache[ds_id] }
                return cached if cached

                props = request(:get,
                                "data_sources/#{ds_id}")["properties"] || {}
                TypeMap.check_property_names!(props.keys)
                Sequel.synchronize { @data_source_cache[ds_id] = props }
            end

            def schema_parse_table(table_name, _opts)
                ds_id = data_source_id_for(table_name)
                raise Error, "Unknown data source: #{table_name}" unless ds_id

                Schema.notion_to_sequel(data_source(ds_id))
            end
        end
    end
end
