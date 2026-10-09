# frozen_string_literal: true

module Sequel
    module Notion
        # A page lists at most 25 relations or people; the rest is read
        # from the page property endpoint, for the properties a row
        # returns. A relation says has_more; people say nothing, so 25
        # of them may be more.
        module DatasetTruncation
            LISTED = 25

            private

            def complete_page(page, sel)
                wanted = sel&.map { it.first.to_s }
                (page["properties"] || {}).each do |name, prop|
                    next if wanted && !wanted.include?(name)

                    complete_property(page["id"], prop) if truncated?(prop)
                end
                page
            end

            def complete_property(page_id, prop)
                type = prop["type"]
                prop[type] = db.notion_property_items(page_id, prop["id"])
                               .map { it[type] }
            end

            def truncated?(prop)
                case prop["type"]
                when "relation" then prop["has_more"] == true
                when "people" then Array(prop["people"]).size >= LISTED
                else false
                end
            end
        end
    end
end
