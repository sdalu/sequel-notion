# frozen_string_literal: true

module Sequel
    module Notion
        # Conditions every page meets, or none does, mixed into
        # FilterCompiler. An empty list compiles to one, as Sequel's SQL
        # adapters read it (IN () is false, NOT IN () true); Notion has no
        # such filter, so and/or fold them away, NOT swaps them, and only
        # a whole filter can be one: no filter sent, or no request.
        module FilterConstants
            EVERYTHING = { "everything" => true }.freeze
            NOTHING    = { "nothing" => true }.freeze

            private

            def constant?(filter)
                filter.equal?(EVERYTHING) || filter.equal?(NOTHING)
            end

            def opposite(filter) = filter.equal?(NOTHING) ? EVERYTHING : NOTHING

            # An and of compiled parts: NOTHING if one is, the EVERYTHING
            # ones dropped; an or the other way round
            def all_of(parts) = folded("and", parts, NOTHING, EVERYTHING)
            def any_of(parts) = folded("or", parts, EVERYTHING, NOTHING)

            def folded(op, parts, absorbing, neutral)
                return absorbing if parts.any? { it.equal?(absorbing) }

                rest = parts.reject { it.equal?(neutral) }
                return neutral if rest.empty?

                rest.one? ? rest.first : { op => rest }
            end
        end
    end
end
