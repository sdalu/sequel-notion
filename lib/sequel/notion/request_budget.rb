# frozen_string_literal: true

module Sequel
    module Notion
        # A ceiling on the Notion requests one query makes, mixed into
        # Database. The budget covers every request sent while the query
        # runs, in this fiber, including the queries a join or a union
        # runs inside it; the request past it raises before it is sent.
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

            private

            def budget_key = :"notion_budget_#{object_id}"

            # Called before each request: count it, or refuse it
            def spend_request!
                budget = Thread.current[budget_key] or return
                if budget.last >= budget.first
                    raise Error, "query stopped after #{budget.first} Notion " \
                                 "request(s), its max_requests; raise it in " \
                                 "client_side(max_requests:)"
                end

                budget[1] += 1
            end
        end
    end
end
