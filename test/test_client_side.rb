# frozen_string_literal: true

require "test_helper"
require "faraday"
require "sequel/adapters/notion"

# What Notion cannot compute is computed in Ruby over every row the query
# returns, and only when the dataset opts in with client_side: without
# it, such a query raises before any request is sent
class TestClientSide < Minitest::Test
    DS_ID = "11111111-2222-3333-4444-555555555555"

    def setup
        @stubs   = Faraday::Adapter::Test::Stubs.new
        @queries = 0
        @db      = Sequel.connect(adapter: :notion, token: "t", test: false,
                                  faraday_adapter: [:test, @stubs])
        @db.register_data_source(:t, DS_ID)
        @stubs.get("/v1/data_sources/#{DS_ID}") do
            json(properties: { "Name" => { "type" => "title" },
                               "N" => { "type" => "number" } })
        end
        @stubs.post("/v1/data_sources/#{DS_ID}/query") do |env|
            @queries += 1
            from = JSON.parse(env.body)["start_cursor"].to_i
            more = from + 1 < @pages
            json(results: [], has_more: more,
                 next_cursor: more ? (from + 1).to_s : nil)
        end
        @pages = 1
        @db.schema(:t) # cached: the budgets below count queries only
    end

    def json(**body)
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
    end

    def ds = @db[:t]

    REFUSED = {
        sum: ->(d) { d.sum(:N) },
        avg: ->(d) { d.avg(:N) },
        min: ->(d) { d.min(:N) },
        max: ->(d) { d.max(:N) },
        count_column: ->(d) { d.count(:N) },
        distinct: ->(d) { d.distinct.all },
        distinct_on: ->(d) { d.distinct(:N).all },
        group: ->(d) { d.group_and_count(:N).all },
        having: ->(d) { d.select_group(:N).having { count.function.* > 1 }.all },
        union: ->(d) { d.union(d).all },
        intersect: ->(d) { d.intersect(d).all },
        except: ->(d) { d.except(d).all },
        join: ->(d) { d.join(Sequel[:t].as(:u), id: :Name).all },
        left_join: ->(d) { d.left_join(Sequel[:t].as(:u), id: :Name).all }
    }.freeze

    def test_ruby_computed_queries_need_client_side
        REFUSED.each do |name, query|
            error = assert_raises(Sequel::Error, name.to_s) { query.(ds) }
            assert_includes error.message, "client_side", name.to_s
        end
        assert_equal 0, @queries
    end

    def test_client_side_allows_them
        REFUSED.each_value { it.(ds.client_side) }
        assert_operator @queries, :>, 0
    end

    def test_plain_reads_need_nothing
        ds.all
        ds.where(N: 1).limit(2).offset(1).all
        assert_equal 0, ds.count
        assert_equal 3, @queries
    end

    # max_requests bounds every request one query makes, counted across
    # the queries a join or union runs; the next one past it raises
    def test_max_requests_stops_the_query_before_the_next_request
        @pages = 5
        error = assert_raises(Sequel::Error) do
            ds.client_side(max_requests: 3).sum(:N)
        end
        assert_includes error.message, "max_requests"
        assert_equal 3, @queries
    end

    def test_max_requests_counts_both_sides_of_a_join
        @pages = 2
        joined = ->(n) { ds.client_side(max_requests: n).join(Sequel[:t].as(:u), id: :Name).all }
        assert_raises(Sequel::Error) { joined.(3) }
        @queries = 0
        joined.(4)
        assert_equal 4, @queries
    end

    def test_each_query_has_its_own_budget
        @pages = 2
        limited = ds.client_side(max_requests: 2)
        2.times { limited.sum(:N) }
        assert_equal 4, @queries
    end

    def test_max_requests_also_bounds_plain_reads
        @pages = 3
        assert_raises(Sequel::Error) { ds.client_side(max_requests: 2).all }
        ds.client_side.all
    end

    def test_a_model_opts_in_through_its_dataset
        klass = Class.new(Sequel::Model(ds))
        assert_raises(Sequel::Error) { klass.sum(:N) }
        assert_nil klass.client_side.sum(:N)
        assert_nil klass.client_side(max_requests: 5).sum(:N)
    end
end
