# frozen_string_literal: true

module Sequel
    module Notion
        # The finished filter, fitted to Notion's shape (rule K), mixed
        # into FilterCompiler. Notion nests and/or two levels deep at
        # most. An "and" directly inside an "and" (or an "or" inside an
        # "or") is spliced into its parent; a filter still too deep has
        # its inner level distributed, (a & b) | c becoming
        # (a | c) & (b | c), up to MAX_CLAUSES clauses; what remains too
        # deep raises rather than being sent to fail with a 400.
        module FilterShape
            MAX_DEPTH   = 2
            MAX_CLAUSES = 32

            private

            def notion_shape(filter)
                flat = flattened(filter)
                flat = distributed(flat) if compound_depth(flat) > MAX_DEPTH
                return flat if compound_depth(flat) <= MAX_DEPTH

                raise too_deep(flat)
            end

            def flattened(filter)
                op = compound_op(filter)
                return filter unless op

                { op => filter[op].flat_map do |kid|
                    kid = flattened(kid)
                    compound_op(kid) == op ? kid[op] : [kid]
                end }
            end

            # Each kid two levels deep, whose op is the other one,
            # rewritten in the root's op and spliced into the root
            def distributed(filter)
                op = compound_op(filter)
                { op => filter[op].flat_map do |kid|
                    compound_depth(kid) == MAX_DEPTH ? swapped(kid, op) : [kid]
                end }
            end

            # The clauses of kid, an "or" of "and"s (or the reverse),
            # rewritten as op's children
            def swapped(kid, op)
                kop     = compound_op(kid)
                choices = kid[kop].map { compound_op(it) == op ? it[op] : [it] }
                clauses = choices.first.product(*choices.drop(1))
                raise too_deep(kid) if clauses.size > MAX_CLAUSES

                clauses.map { conjoined(kop, it.uniq) }.uniq
            end

            def conjoined(op, conds)
                conds.one? ? conds.first : { op => conds }
            end

            def too_deep(filter)
                Sequel::Error.new("Notion nests and/or at most #{MAX_DEPTH} " \
                                  "levels deep: #{filter.inspect}")
            end

            def compound_depth(filter)
                op = compound_op(filter)
                op ? 1 + filter[op].map { compound_depth(it) }.max : 0
            end

            def compound_op(filter)
                %w[and or].find { filter.key?(it) }
            end
        end
    end
end
