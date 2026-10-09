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

        Sequel::Model::ClassMethods.prepend(ModelSupport)
        Sequel::Model::InstanceMethods.prepend(ModelSaveSupport)
    end
end
