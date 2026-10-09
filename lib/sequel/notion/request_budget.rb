# frozen_string_literal: true

module Sequel
    module Notion
        # A ceiling on the Notion requests one query makes, mixed into
        # Database. The budget covers every request answered 200 while
        # the query runs, in this fiber, including the queries a join or
        # a union runs inside it; the request past it raises before it is
        # sent. A rate-limited attempt the retry absorbs, or a request
        # that fails, spends nothing.
        module RequestBudget
            # Run the block under a budget of +max+ requests (nil: none).
            # A query run inside a budgeted one spends the outer budget.
            def with_request_budget(max)
                return yield if max.nil? || Thread.current[budget_key]

                begin
                    Thread.current[budget_key] = [max, 0]
                    yield
                ensure
                    Thread.current[budget_key] = nil
                end
            end

            # Run the block with no budget: what the caller does with a
            # row (another query, say) is no part of the query that
            # gave it
            def outside_request_budget
                saved = Thread.current[budget_key]
                Thread.current[budget_key] = nil
                yield
            ensure
                Thread.current[budget_key] = saved
            end

            private

            # The block's answer, refused once the budget is spent and
            # counted once it succeeds
            def within_budget
                check_request_budget!
                yield.tap { spend_request! }
            end

            def budget_key = :"notion_budget_#{object_id}"

            # Called before each request: refuse it once the budget is spent
            def check_request_budget!
                budget = Thread.current[budget_key] or return
                return if budget.last < budget.first

                raise Error, "query stopped after #{budget.first} Notion " \
                             "request(s), its max_requests; raise it in " \
                             "client_side(max_requests:)"
            end

            # Called after each request answered 200
            def spend_request!
                budget = Thread.current[budget_key] or return
                budget[1] += 1
            end
        end
    end
end
