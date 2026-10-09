# frozen_string_literal: true

require "test_helper"
require "faraday"
require "sequel/adapters/notion"

# Notion lists at most 25 relations or people in a page; the rest comes
# from the page property endpoint, page by page
class TestTruncation < Minitest::Test
    DS_ID = "11111111-2222-3333-4444-555555555555"

    PROPS = {
        "Name" => { "type" => "title" },
        "Rel" => { "type" => "relation" },
        "Who" => { "type" => "people" }
    }.freeze

    def setup
        @stubs = Faraday::Adapter::Test::Stubs.new
        @items = []
        @db    = Sequel.connect(adapter: :notion, token: "t", test: false,
                                faraday_adapter: [:test, @stubs])
        @db.register_data_source(:tasks, DS_ID)
        @stubs.get("/v1/data_sources/#{DS_ID}") { json(properties: PROPS) }
    end

    def json(**body)
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
    end

    def ids(prefix, count) = Array.new(count) { "#{prefix}#{it}" }

    def page(rel:, more: false, who: [])
        { "object" => "page", "id" => "p1", "in_trash" => false,
          "properties" => {
              "Name" => { "id" => "title", "type" => "title",
                          "title" => [{ "plain_text" => "a" }] },
              "Rel" => { "id" => "r%3D", "type" => "relation",
                         "relation" => rel.map { { "id" => it } },
                         "has_more" => more },
              "Who" => { "id" => "w%3D", "type" => "people",
                         "people" => who.map { { "id" => it } } }
          } }
    end

    def serve(page)
        @stubs.post("/v1/data_sources/#{DS_ID}/query") do
            json(results: [page], has_more: false)
        end
    end

    # The property endpoint, serving +all+ items of +type+ 20 at a time
    def serve_items(prop_id, type, all)
        @stubs.get("/v1/pages/p1/properties/#{prop_id}") do |env|
            from = env.params["start_cursor"].to_i
            @items << [prop_id, from]
            more = from + 20 < all.size
            json(object: "list", has_more: more,
                 next_cursor: more ? (from + 20).to_s : nil,
                 results: all[from, 20].map do
                     { "object" => "property_item", "type" => type,
                       type => { "id" => it } }
                 end)
        end
    end

    def test_a_truncated_relation_is_fetched_in_full
        serve(page(rel: ids("r", 25), more: true))
        serve_items("r%3D", "relation", ids("r", 30))
        assert_equal ids("r", 30), @db[:tasks].first[:Rel]
        assert_equal [["r%3D", 0], ["r%3D", 20]], @items
    end

    def test_a_complete_relation_costs_no_request
        serve(page(rel: ids("r", 25)))
        assert_equal ids("r", 25), @db[:tasks].first[:Rel]
        assert_empty @items
    end

    # Notion flags no truncation for people: 25 of them may be more
    def test_twenty_five_people_are_fetched_in_full
        serve(page(rel: [], who: ids("u", 25)))
        serve_items("w%3D", "people", ids("u", 27))
        assert_equal ids("u", 27), @db[:tasks].first[:Who]
    end

    def test_a_property_not_selected_is_not_fetched
        serve(page(rel: ids("r", 25), more: true))
        assert_equal({ Name: "a" }, @db[:tasks].select(:Name).first)
        assert_empty @items
    end
end
