# frozen_string_literal: true

module Sequel
    module Notion
        # Static lookup tables shared by the filter-compiling mixins
        # (FilterHelpers, FilterPredicates, FilterLike, FilterComparison,
        # FilterNegation). Pure data, no behaviour.
        module FilterTables
            OPERATOR_MAP = {
                :"=" => "equals",
                :"!=" => "does_not_equal",
                :> => "greater_than",
                :< => "less_than",
                :>= => "greater_than_or_equal_to",
                :<= => "less_than_or_equal_to"
            }.freeze

            # Mirrors an operator when the comparison's operands are swapped
            # (rule S): a < b  ==  b > a
            MIRROR_OPERATOR = {
                :< => :>,
                :> => :<,
                :<= => :>=,
                :>= => :<=,
                :"=" => :"=",
                :"!=" => :"!="
            }.freeze

            FILTER_TYPE_KEY = {
                "title" => "rich_text",
                "rich_text" => "rich_text",
                "url" => "rich_text",
                "email" => "rich_text",
                "phone_number" => "phone_number",
                "created_time" => "date",
                "last_edited_time" => "date",
                "date" => "date",
                "number" => "number",
                "select" => "select",
                "multi_select" => "multi_select",
                "status" => "status",
                "checkbox" => "checkbox",
                "people" => "people",
                "relation" => "relation",
                "files" => "files",
                "formula" => "formula"
            }.freeze

            RICH_TEXT_OPS = %w[equals does_not_equal contains does_not_contain
                               starts_with ends_with is_empty
                               is_not_empty].freeze

            SUPPORTED_OPS = {
                "rich_text" => RICH_TEXT_OPS,
                "string" => RICH_TEXT_OPS, # formula inner key for String values
                "number" => %w[equals does_not_equal greater_than less_than
                               greater_than_or_equal_to
                               less_than_or_equal_to is_empty is_not_empty],
                "select" => %w[equals does_not_equal is_empty is_not_empty],
                "multi_select" => %w[contains does_not_contain is_empty
                                     is_not_empty],
                "status" => %w[equals does_not_equal is_empty is_not_empty],
                "date" => %w[equals before after on_or_before on_or_after
                             is_empty is_not_empty],
                "checkbox" => %w[equals does_not_equal],
                "phone_number" => %w[equals does_not_equal contains
                                     does_not_contain starts_with ends_with
                                     is_empty is_not_empty],
                "people" => %w[contains does_not_contain is_empty
                               is_not_empty],
                "relation" => %w[contains does_not_contain is_empty
                                 is_not_empty],
                "files" => %w[is_empty is_not_empty]
            }.freeze

            DATE_OPERATOR_MAP = {
                "greater_than" => "after",
                "less_than" => "before",
                "greater_than_or_equal_to" => "on_or_after",
                "less_than_or_equal_to" => "on_or_before"
            }.freeze

            # Explicit inverse table for negation (rule G).
            NEGATE_MAP = {
                "equals" => "does_not_equal",
                "does_not_equal" => "equals",
                "contains" => "does_not_contain",
                "does_not_contain" => "contains",
                "is_empty" => "is_not_empty",
                "is_not_empty" => "is_empty",
                "greater_than" => "less_than_or_equal_to",
                "less_than_or_equal_to" => "greater_than",
                "less_than" => "greater_than_or_equal_to",
                "greater_than_or_equal_to" => "less_than",
                "before" => "on_or_after",
                "on_or_after" => "before",
                "after" => "on_or_before",
                "on_or_before" => "after"
            }.freeze

            # Property types whose (not)equal comparisons are expressed
            # through contains/does_not_contain instead (rule IN).
            CONTAINS_TYPES = %w[multi_select people relation].freeze
        end
    end
end
