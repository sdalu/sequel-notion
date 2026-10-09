# frozen_string_literal: true

require "json"

require "faraday"
require "faraday/retry"
require "sequel"

require "sequel/notion/dataset"
require "sequel/notion/errors"
require "sequel/notion/model_support"
require "sequel/notion/page_api"
require "sequel/notion/registry"
require "sequel/notion/request_budget"
require "sequel/notion/schema"
require "sequel/notion/schema_lookup"
require "sequel/notion/type_map"
require "sequel/notion/version"

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
            include RequestBudget
            include SchemaLookup

            set_adapter_scheme :notion

            def initialize(...)
                super
                @data_source_cache = {}
                @data_source_epoch = Hash.new(0)
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
            def transaction(opts = OPTS)
                refuse_rollback_always!(opts)
                synchronize { yield it }
            rescue Rollback
                raise if opts[:rollback] == :reraise
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

            # One Notion request: logged through Sequel's loggers, and any
            # HTTP failure re-raised as a Sequel::DatabaseError. Only its
            # 200 spends the query's budget, after the retries.
            def request(verb, path, body = nil)
                within_budget do
                    synchronize do |conn|
                        log_connection_yield("#{verb.upcase} #{path}", conn,
                                             body && [body]) do
                            conn.public_send(verb, path, body).body
                        end
                    end
                end
            rescue Faraday::Error => e
                raise database_error(e)
            end

            # Where Sequel sends SQL to run: run, <<, truncate, the
            # with_sql_* writes and every schema change
            def execute(sql, _opts = OPTS)
                raise Error, "Notion takes no SQL: #{sql}"
            end

            private

            # A number column is :float, and Sequel's model typecast would
            # turn 5 into 5.0; Notion keeps, and reads back, an Integer
            def typecast_value_float(value)
                value.is_a?(Integer) ? value : super
            end

            def refuse_rollback_always!(opts)
                return unless opts[:rollback] == :always

                raise Error, "Notion has no transactions to roll back"
            end

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
        end
    end
end
