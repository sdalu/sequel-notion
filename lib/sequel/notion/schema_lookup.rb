# frozen_string_literal: true

require "sequel/notion/schema"

module Sequel
    module Notion
        # What the filter compiler needs to know of a data source, read
        # from its cached properties; mixed into Database
        module SchemaLookup
            # Property name => Notion type, for one data source
            def property_type_map(ds_id)
                data_source(ds_id).transform_values { it["type"] }
            end

            # Rollup name => the kind of value it gives, for one data source
            def rollup_kinds(ds_id)
                data_source(ds_id).select { |_, p| p["type"] == "rollup" }
                                  .transform_values { Schema.rollup_kind(it) }
            end
        end
    end
end
