# frozen_string_literal: true

require "test_helper"
require "faraday"
require "sequel/adapters/notion"

# Aggregates and DISTINCT, computed in Ruby over the rows the query
# returns, as SQL defines them: NULLs skipped, NULL over no value
class TestAggregates < Minitest::Test
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
        @stubs.post("/v1/data_sources/#{DS_ID}/query") do
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

    def ds = @db[:t].client_side

    def test_sum_min_max_avg_skip_nulls
        assert_equal 5, ds.sum(:N)
        assert_equal 1, ds.min(:N)
        assert_equal 2, ds.max(:N)
        assert_in_delta 5.0 / 3, ds.avg(:N)
        assert_equal "y", ds.max(:Kind)
    end

    def test_aggregates_honour_limit
        assert_equal 3, ds.limit(2).sum(:N)
        assert_equal 2, ds.limit(2, 1).sum(:N)
    end

    def test_aggregates_of_no_value_are_nil
        assert_nil ds.offset(10).sum(:N)
        assert_nil ds.offset(10).avg(:N)
        assert_nil ds.offset(10).max(:N)
    end

    def test_count_of_a_column_skips_nulls
        assert_equal 4, ds.count
        assert_equal 3, ds.count(:N)
        assert_equal 3, ds.count(:Kind)
    end

    def test_aggregates_refuse_expressions_and_text_sums
        assert_raises(Sequel::Error) { ds.sum(Sequel[:N] + 1) }
        assert_raises(Sequel::Error) { ds.sum(:Kind) }
        assert_raises(Sequel::Error) { ds.sum(:Nope) }
        assert_raises(Sequel::Error) { ds.count { |o| o.N } }
    end

    # DISTINCT comes before LIMIT and OFFSET, as in SQL
    def test_distinct_rows
        assert_equal [{ Kind: "x" }, { Kind: "y" }, { Kind: nil }],
                     ds.select(:Kind).distinct.all
        assert_equal [{ Kind: "y" }], ds.select(:Kind).distinct.limit(1, 1).all
        assert_equal [1, 2, nil], ds.distinct.select_map(:N)
        assert_equal 3, ds.select(:N).distinct.count
    end

    # DISTINCT ON keeps the first row of each key, in the query's order
    def test_distinct_on
        assert_equal %w[n0 n1 n3],
                     ds.distinct(:Kind).select(:Name).map(:Name)
        assert_equal [{ Kind: "x", N: 1 }, { Kind: "y", N: 2 }],
                     ds.distinct(:Kind).select(:Kind, :N).limit(2).all
    end
end
