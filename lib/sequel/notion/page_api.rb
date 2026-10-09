# frozen_string_literal: true

module Sequel
    module Notion
        # The page and query endpoints the Dataset calls, over
        # Database#request
        module PageApi
            def notion_query(data_source_id, body)
                request(:post, "data_sources/#{data_source_id}/query", body)
            end

            def notion_get_page(page_id)
                request(:get, "pages/#{page_id}")
            end

            # Every item of a paginated page property (relation, people)
            def notion_property_items(page_id, property_id)
                path   = "pages/#{page_id}/properties/#{property_id}"
                items  = []
                cursor = nil
                loop do
                    resp = request(:get, path,
                                   cursor && { start_cursor: cursor })
                    items.concat(resp["results"] || [])
                    break items unless resp["has_more"]

                    cursor = resp["next_cursor"]
                end
            end

            def notion_create_page(data_source_id, properties)
                request(:post, "pages",
                        parent: { type: "data_source_id",
                                  data_source_id: data_source_id },
                        properties: properties)
            end

            def notion_update_page(page_id, properties, in_trash: nil)
                body = { properties: properties }
                body[:in_trash] = in_trash unless in_trash.nil?
                request(:patch, "pages/#{page_id}", body)
            end

            def notion_trash_page(page_id)
                request(:patch, "pages/#{page_id}", in_trash: true)
            end
        end
    end
end
