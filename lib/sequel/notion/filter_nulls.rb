# frozen_string_literal: true

module Sequel
    module Notion
        # SQL's rule for empty values (rule E), mixed into FilterCompiler
        # and applied once, to the finished filter. Notion's
        # does_not_equal and does_not_contain match an empty property;
        # SQL's != and NOT LIKE never match NULL. Each such leaf gets an
        # is_not_empty beside it: spliced into an enclosing "and", so
        # nesting does not grow, else wrapped in one. It runs after
        # negation, which would otherwise turn the guard into is_empty.
        module FilterNulls
            NEGATIVE_OPS = %w[does_not_equal does_not_contain].freeze

            # Never empty (checkbox), or emptiness unknown (formula)
            UNGUARDED = %w[checkbox formula].freeze

            private

            def sql_nulls(filter) = conjunction(guarded(filter))

            # The conditions an "and" holding +filter+ needs
            def guarded(filter)
                if filter.key?("and")
                    [{ "and" => filter["and"].flat_map { guarded(it) }.uniq }]
                elsif filter.key?("or")
                    [{ "or" => filter["or"].map { conjunction(guarded(it)) } }]
                else
                    guarded_leaf(filter)
                end
            end

            def guarded_leaf(leaf)
                key = (leaf.keys - ["property"]).first
                return [leaf] if UNGUARDED.include?(key) ||
                                 !NEGATIVE_OPS.include?(leaf[key].keys.first)

                [leaf, { "property" => leaf["property"],
                         key => { "is_not_empty" => true } }]
            end

            def conjunction(conds)
                conds.one? ? conds.first : { "and" => conds }
            end
        end
    end
end
