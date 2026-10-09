# frozen_string_literal: true

module Sequel
    module Notion
        # Sequel::Model precomputes SQL for primary key lookups and
        # deletes on "simple" tables, and runs it outside the dataset.
        # A model over a Notion dataset is never simple, so those go
        # through where(id: ...) like any other query.
        module ModelSupport
            # The model's dataset, allowing what Notion cannot compute to
            # be computed in Ruby: Task.client_side.sum(:Hours)
            def client_side(...) = dataset.client_side(...)

            private

            def convert_input_dataset(source)
                ds = super
                self.simple_table = nil if ds.is_a?(Notion::Dataset)
                ds
            end
        end

        # A row reads back partial values (a date's start only, the first
        # 25 relations or people, rich text as plain text), so a save
        # writes back only the columns that were changed, never the
        # whole row.
        module ModelSaveSupport
            private

            def _save_update_all_columns_hash
                return super unless model.dataset.is_a?(Notion::Dataset)

                _save_update_changed_columns_hash
            end
        end

        # Notion cannot sort by page id: a model over a Notion dataset
        # adds no primary key order, so paged_each streams in Notion's
        # order and last needs an explicit one.
        module ModelOrderSupport
            private

            def _primary_key_order
                super unless is_a?(Notion::Dataset)
            end
        end

        Sequel::Model::ClassMethods.prepend(ModelSupport)
        Sequel::Model::DatasetMethods.prepend(ModelOrderSupport)
        Sequel::Model::InstanceMethods.prepend(ModelSaveSupport)
    end
end
