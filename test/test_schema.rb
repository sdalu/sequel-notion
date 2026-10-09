# frozen_string_literal: true

require "test_helper"
require "faraday"
require "sequel/adapters/notion"

# Data source schema: column types, rollup kinds, and rollup filters
# reaching Notion through a dataset
class TestSchema < Minitest::Test
    DS_ID = "11111111-2222-3333-4444-555555555555"

    def rollup(function) = { "type" => "rollup",
                             "rollup" => { "function" => function } }

    def test_rollup_kind_follows_its_function
        schema = Sequel::Notion::Schema
        assert_equal "number", schema.rollup_kind(rollup("sum"))
        assert_equal "date", schema.rollup_kind(rollup("latest_date"))
        assert_equal "array", schema.rollup_kind(rollup("show_original"))
        assert_nil schema.rollup_kind(rollup("date_range"))
    end

    def test_a_rollup_filter_reaches_notion
        stubs = Faraday::Adapter::Test::Stubs.new
        sent  = []
        stubs.get("/v1/data_sources/#{DS_ID}") do
            json(properties: { "Sum" => rollup("sum"),
                               "All" => rollup("show_original") })
        end
        stubs.post("/v1/data_sources/#{DS_ID}/query") do |env|
            sent << JSON.parse(env.body)["filter"]
            json(results: [], has_more: false)
        end
        db = Sequel.connect(adapter: :notion, token: "t", test: false,
                            faraday_adapter: [:test, stubs])
        db.register_data_source(:t, DS_ID)
        db[:t].where(Sum: 7).all
        assert_equal [{ "property" => "Sum",
                        "rollup" => { "number" => { "equals" => 7 } } }], sent
        assert_raises(Sequel::Error) { db[:t].where(All: "x").all }
    end

    def json(**body)
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
    end
end
