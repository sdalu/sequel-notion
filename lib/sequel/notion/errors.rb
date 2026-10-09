# frozen_string_literal: true

module Sequel
    module Notion
        # A Notion object (page, data source) that does not exist, or that
        # the integration cannot see
        class NotFoundError < Sequel::DatabaseError; end
    end
end
