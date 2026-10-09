# frozen_string_literal: true

require "sequel/notion/schema"

module Sequel
    module Notion
        # A data source's properties, fetched once and cached, and what
        # Sequel (columns) and the filter compiler (types, rollup kinds)
        # read from them; mixed into Database
        module SchemaLookup
            # Sequel caches columns per table name, and another name for
            # the data source (an alias, its id) would keep the old ones:
            # all are dropped, rebuilt from the data source cache with no
            # request
            def refresh_schema!(table_name)
                ds_id = data_source_id_for(table_name)
                Sequel.synchronize do
                    @data_source_cache.delete(ds_id)
                    @data_source_epoch[ds_id] += 1
                    @schemas.clear
                end
                remove_cached_schema(table_name)
            end

            # Property name => Notion type, for one data source
            def property_type_map(ds_id)
                data_source(ds_id).transform_values { it["type"] }
            end

            # Rollup name => the kind of value it gives, for one data source
            def rollup_kinds(ds_id)
                data_source(ds_id).select { |_, p| p["type"] == "rollup" }
                                  .transform_values { Schema.rollup_kind(it) }
            end

            private

            # Data source object properties, fetched once and cached. A
            # fetch that a refresh_schema! overtook fetches again, so its
            # older answer never replaces the newer one
            def data_source(ds_id)
                loop do
                    epoch, cached = cached_properties(ds_id)
                    return cached if cached

                    props = fetch_properties(ds_id)
                    return props if store_properties(ds_id, epoch, props)
                end
            end

            def cached_properties(ds_id)
                Sequel.synchronize do
                    [@data_source_epoch[ds_id], @data_source_cache[ds_id]]
                end
            end

            # Cache them, unless a refresh came in meanwhile
            def store_properties(ds_id, epoch, props)
                Sequel.synchronize do
                    next false unless @data_source_epoch[ds_id] == epoch

                    @data_source_cache[ds_id] = props
                    true
                end
            end

            def fetch_properties(ds_id)
                props = request(:get,
                                "data_sources/#{ds_id}")["properties"] || {}
                TypeMap.check_property_names!(props.keys)
                props
            end

            def schema_parse_table(table_name, _opts)
                ds_id = data_source_id_for(table_name)
                raise Error, "Unknown data source: #{table_name}" unless ds_id

                Schema.notion_to_sequel(data_source(ds_id))
            end
        end
    end
end
