# frozen_string_literal: true

require "test_helper"
require "faraday"
require "sequel/adapters/notion"

# GROUP BY, computed in Ruby over the rows the query returns: one
# running aggregate per group, then ORDER, OFFSET and LIMIT over groups
class TestGrouping < Minitest::Test
    DS_ID = "11111111-2222-3333-4444-555555555555"

    PROPS = { "Name" => { "type" => "title" }, "N" => { "type" => "number" },
              "Kind" => { "type" => "select" } }.freeze

    ROWS = [[1, "x"], [2, "y"], [nil, "x"], [2, nil]].freeze

    def setup
        @stubs = Faraday::Adapter::Test::Stubs.new
        @db    = Sequel.connect(adapter: :notion, token: "t", test: false,
                                faraday_adapter: [:test, @stubs])
        @db.register_data_source(:t, DS_ID)
        @stubs.get("/v1/data_sources/#{DS_ID}") { json(properties: PROPS) }
        @sent  = []
        @stubs.post("/v1/data_sources/#{DS_ID}/query") do |env|
            @sent << JSON.parse(env.body)
            json(results: ROWS.each_with_index.map { |(n, k), i| page(i, n, k) },
                 has_more: false)
        end
    end

    def json(**body)
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
    end

    def page(index, number, kind)
        { "object" => "page", "id" => "p#{index}", "in_trash" => false,
          "properties" => {
              "Name" => { "type" => "title",
                          "title" => [{ "plain_text" => "n#{index}" }] },
              "N" => { "type" => "number", "number" => number },
              "Kind" => { "type" => "select",
                          "select" => kind && { "name" => kind } }
          } }
    end

    def ds = @db[:t]

    def test_group_and_count
        assert_equal [{ Kind: "x", count: 2 }, { Kind: "y", count: 1 },
                      { Kind: nil, count: 1 }],
                     ds.group_and_count(:Kind).order(:Kind).all
    end

    def test_aggregates_per_group
        rows = ds.group(:Kind).order(:Kind)
                 .select(:Kind) { [sum(:N).as(:s), max(:N).as(:m),
                                   count(:N).as(:c), avg(:N).as(:a)] }.all
        assert_equal [{ Kind: "x", s: 1, m: 1, c: 1, a: 1.0 },
                      { Kind: "y", s: 2, m: 2, c: 1, a: 2.0 },
                      { Kind: nil, s: 2, m: 2, c: 1, a: 2.0 }], rows
    end

    def test_where_runs_before_and_order_limit_after
        ds.where(N: 1).group_and_count(:Kind).all
        assert_equal({ "property" => "N", "number" => { "equals" => 1 } },
                     @sent.last["filter"])
        assert_nil @sent.last["sorts"]
        assert_equal [{ Kind: "x", count: 2 }],
                     ds.group_and_count(:Kind)
                       .order(Sequel.desc(:count), :Kind).limit(1).all
        assert_equal 3, ds.group_and_count(:Kind).count
        assert_equal %w[x y], ds.select_group(:Kind).order(:Kind)
                                 .map(:Kind).compact
    end

    def test_grouped_columns
        assert_equal %i[Kind count], ds.group_and_count(:Kind).columns
    end

    # HAVING filters the groups, on an aggregate written out or on an
    # output's name, with SQL's NULL rules
    def test_having
        assert_equal [{ Kind: "x", count: 2 }],
                     ds.group_and_count(:Kind)
                       .having { count.function.* > 1 }.all
        assert_equal [{ Kind: "x", count: 2 }],
                     ds.group_and_count(:Kind).having(Sequel[:count] > 1).all
        assert_equal [{ Kind: "y" }, { Kind: nil }],
                     ds.select_group(:Kind).having { max(:N) >= 2 }.all
        assert_equal [{ Kind: "x" }],
                     ds.select_group(:Kind).having(Kind: %w[x z]).all
    end

    def test_ungrouped_columns_and_text_sums_raise
        assert_raises(Sequel::Error) { ds.group(:Kind).select(:N).all }
        assert_raises(Sequel::Error) do
            ds.group_and_count(:Kind).having(Sequel[:N] > 1).all
        end
        assert_raises(Sequel::Error) do
            ds.group(:N).select(:N) { sum(:Kind).as(:s) }.all
        end
    end
end
