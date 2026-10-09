# frozen_string_literal: true

require "test_helper"
require "faraday"
require "sequel/adapters/notion"

# UNION, INTERSECT and EXCEPT, computed in Ruby over the rows of each
# query, as SQL defines them
class TestCompounds < Minitest::Test
    DS_ID = "11111111-2222-3333-4444-555555555555"

    PROPS = { "Name" => { "type" => "title" },
              "N" => { "type" => "number" } }.freeze

    def setup
        @stubs = Faraday::Adapter::Test::Stubs.new
        @db    = Sequel.connect(adapter: :notion, token: "t", test: false,
                                faraday_adapter: [:test, @stubs])
        @db.register_data_source(:t, DS_ID)
        @stubs.get("/v1/data_sources/#{DS_ID}") { json(properties: PROPS) }
        @stubs.post("/v1/data_sources/#{DS_ID}/query") do |env|
            n = JSON.parse(env.body).dig("filter", "number", "equals")
            json(results: [[0, 1], [1, 2], [2, 2]]
                     .select { n.nil? || it.last == n }
                     .map { |i, v| page(i, v) }, has_more: false)
        end
    end

    def json(**body)
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
    end

    def page(index, number)
        { "object" => "page", "id" => "p#{index}", "in_trash" => false,
          "properties" => {
              "Name" => { "type" => "title",
                          "title" => [{ "plain_text" => "n#{index}" }] },
              "N" => { "type" => "number", "number" => number }
          } }
    end

    def ns(number) = @db[:t].client_side.where(N: number).select(:N)

    def test_union_drops_repeats_and_all_keeps_them
        assert_equal [{ N: 1 }, { N: 2 }], ns(1).union(ns(2)).all
        assert_equal [{ N: 1 }, { N: 2 }, { N: 2 }],
                     ns(1).union(ns(2), all: true).all
    end

    def test_intersect_and_except
        all = @db[:t].client_side.select(:N)
        assert_equal [{ N: 2 }], all.intersect(ns(2)).all
        assert_equal [{ N: 1 }], all.except(ns(2)).all
    end

    def test_compound_order_limit_and_count
        both = ns(1).union(ns(2), all: true)
        assert_equal [{ N: 2 }, { N: 2 }],
                     both.order(Sequel.desc(:N)).limit(2).all
        assert_equal 3, both.count
    end

    def test_compound_with_a_where_raises
        assert_raises(Sequel::Error) { ns(1).union(ns(2)).where(N: 1).all }
    end

    # A select on the result projects the combined rows
    def test_compound_select
        both = @db[:t].client_side.where(N: 1).select(:N, :Name)
                      .union(@db[:t].client_side.where(N: 2).select(:N, :Name))
        assert_equal [{ name: "n0" }, { name: "n1" }, { name: "n2" }],
                     both.select(Sequel[:Name].as(:name)).order(:Name).all
        assert_equal [1, 2], ns(1).union(ns(2)).select_map(:N)
        assert_equal %i[name], both.select(Sequel[:Name].as(:name)).columns
        assert_raises(Sequel::Error) do
            ns(1).union(ns(2)).select(:Name).all
        end
    end

    # As in SQL, a combination takes the first query's column names, the
    # others' values by position
    def test_compound_takes_the_first_query_names
        a = @db[:t].client_side.where(N: 1).select(Sequel[:N].as(:a))
        b = @db[:t].client_side.where(N: 2).select(Sequel[:N].as(:b))
        assert_equal [{ a: 1 }, { a: 2 }], a.union(b).order(:a).all
        assert_equal [{ a: 2 }], b.select(Sequel[:N].as(:a))
                                  .intersect(b).all
        assert_equal [], a.except(a.select(Sequel[:N].as(:z))).all
        assert_raises(Sequel::Error) do
            a.union(@db[:t].client_side.select(:N, :Name)).all
        end
    end

    # A subquery that combines nothing is no compound: a clear refusal
    def test_from_self_raises_a_sequel_error
        assert_raises(Sequel::Error) do
            @db[:t].client_side.select(:N).from_self.all
        end
    end
end
