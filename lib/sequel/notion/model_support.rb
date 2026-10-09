# frozen_string_literal: true

module Sequel
    module Notion
        # Sequel::Model precomputes SQL for primary key lookups and
        # deletes on "simple" tables, and runs it outside the dataset.
        # A model over a Notion dataset is never simple, so those go
        # through where(id: ...) like any other query.
        module ModelSupport
            private

            def convert_input_dataset(source)
                ds = super
                self.simple_table = nil if ds.is_a?(Notion::Dataset)
                ds
            end
        end

        Sequel::Model::ClassMethods.prepend(ModelSupport)
    end
end
