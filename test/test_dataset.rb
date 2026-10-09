# frozen_string_literal: true

require "test_helper"
require "faraday"
require "sequel/adapters/notion"

# End-to-end through Sequel and the real Faraday middleware stack, with
# Notion replaced by Faraday's test adapter.
class TestDataset < Minitest::Test
    DS_ID = "11111111-2222-3333-4444-555555555555"

    PROPS = {
        "Name" => { "type" => "title" },
        "Done" => { "type" => "checkbox" },
        "Status" => { "type" => "status" },
        "N" => { "type" => "number" }
    }.freeze

    def setup
        @stubs = Faraday::Adapter::Test::Stubs.new
        @calls = []
        @db    = Sequel.connect(adapter: :notion, token: "t", test: false,
                                faraday_adapter: [:test, @stubs])
        @db.register_data_source(:tasks, DS_ID)
        @stubs.get("/v1/data_sources/#{DS_ID}") do
            json(properties: PROPS)
        end
    end

    def page(id, name, done: false)
        { "object" => "page", "id" => id, "in_trash" => false,
          "parent" => { "type" => "data_source_id",
                        "data_source_id" => DS_ID },
          "properties" => {
              "Name" => { "type" => "title",
                          "title" => [{ "plain_text" => name }] },
              "Done" => { "type" => "checkbox", "checkbox" => done }
          } }
    end

    def json(status = 200, headers = {}, **body)
        [status, { "Content-Type" => "application/json" }.merge(headers),
         JSON.generate(body)]
    end

    # Serve the query endpoint from pages, two per response
    def serve_query(pages)
        @stubs.post("/v1/data_sources/#{DS_ID}/query") do |env|
            body = JSON.parse(env.body)
            @calls << body
            from  = body["start_cursor"].to_i
            slice = pages[from, 2]
            more  = from + 2 < pages.size
            json(results: slice, has_more: more,
                 next_cursor: more ? (from + 2).to_s : nil)
        end
    end

    def three_pages
        serve_query([page("p1", "a"), page("p2", "b"),
                     page("p3", "c")])
    end

    def test_all_paginates
        three_pages
        assert_equal %w[a b c], @db[:tasks].map(:Name)
        assert_equal 2, @calls.size
    end

    def test_get_returns_the_selected_column
        three_pages
        assert_equal "a", @db[:tasks].get(:Name)
        assert_equal %w[a b c], @db[:tasks].select_map(:Name)
    end

    def test_select_applies_aliases
        three_pages
        row = @db[:tasks].select(Sequel.as(:Name, :n)).first
        assert_equal({ n: "a" }, row)
    end

    def test_offset_and_limit
        three_pages
        assert_equal %w[b c], @db[:tasks].offset(1).map(:Name)
        assert_equal %w[b], @db[:tasks].limit(1, 1).map(:Name)
    end

    def test_count_and_empty
        three_pages
        assert_equal 3, @db[:tasks].count
        refute_predicate @db[:tasks], :empty?
    end

    def test_where_true_filters_checkbox
        three_pages
        @db[:tasks].where(Done: true).all
        assert_equal({ "property" => "Done",
                       "checkbox" => { "equals" => true } },
                     @calls.first["filter"])
    end

    def test_unsupported_clause_raises
        assert_raises(Sequel::Error) do
            @db[:tasks].join(:other, id: :id).all
        end
    end

    def test_lookup_by_id_gets_the_page
        @stubs.get("/v1/pages/p2") { json(**page("p2", "b")) }
        @stubs.get("/v1/pages/zz") { json(404, object: "error") }
        assert_equal ["b"], @db[:tasks].where(id: %w[p2 zz]).map(:Name)
    end

    def test_repeated_ids_yield_one_row
        @stubs.get("/v1/pages/p1") { json(**page("p1", "a")) }
        assert_equal 1, @db[:tasks].where(id: %w[p1 p1]).count
    end

    def test_property_named_id_is_refused
        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.get("/v1/data_sources/#{DS_ID}") do
            json(properties: { "id" => { "type" => "rich_text" } })
        end
        db = Sequel.connect(adapter: :notion, token: "t", test: false,
                            faraday_adapter: [:test, stubs])
        db.register_data_source(:tasks, DS_ID)
        assert_raises(Sequel::Error) { db.schema(:tasks) }
    end

    def test_page_with_a_property_named_in_trash_is_refused
        bad = page("p1", "a")
        bad["properties"]["in_trash"] = { "type" => "checkbox",
                                          "checkbox" => true }
        serve_query([bad])
        assert_raises(Sequel::Error) { @db[:tasks].all }
    end

    def test_id_conditions_intersect_across_dash_spellings
        id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        @stubs.get("/v1/pages/#{id.delete("-")}") do
            json(**page(id, "a"))
        end
        rows = @db[:tasks].where(id: id).where(id: id.delete("-"))
        assert_equal ["a"], rows.map(:Name)
    end

    # Sequel also takes SQL for update; Notion has none
    def test_update_with_sql_raises_a_sequel_error
        assert_raises(Sequel::Error) do
            @db[:tasks].update(Sequel.lit("N = N + 1"))
        end
    end

    def test_update_collects_ids_before_patching
        three_pages
        patched = []
        @stubs.patch(%r{/v1/pages/}) do |env|
            patched << [env.url.path, JSON.parse(env.body)]
            json(object: "page")
        end
        assert_equal 3, @db[:tasks].where(Done: false).update(Status: "Done")
        assert_equal 2, @calls.size # one paginated query, then the patches
        assert_equal({ "properties" =>
                           { "Status" => { "status" => { "name" => "Done" } } } },
                     patched.first.last)
    end

    def test_insert_types_the_payload
        sent = nil
        @stubs.post("/v1/pages") do |env|
            sent = JSON.parse(env.body)
            json(object: "page", id: "new")
        end
        assert_equal "new", @db[:tasks].insert(Name: "x", Status: "Todo")
        assert_equal({ "type" => "data_source_id", "data_source_id" => DS_ID },
                     sent["parent"])
        assert_equal "x", sent.dig("properties", "Name", "title", 0,
                                   "text", "content")
    end

    def test_schema_has_page_columns_and_is_cached
        gets = 0
        @stubs.get("/v1/data_sources/other") do
            gets += 1
            json(properties: PROPS)
        end
        @db.register_data_source(:other, "other")
        cols = @db.schema(:other).to_h
        @db.schema(:other)
        @db[:other].columns
        assert cols[:id][:primary_key]
        assert_equal :boolean, cols[:Done][:type]
        assert_equal 1, gets
    end

    def test_model_create_and_reload
        @stubs.post("/v1/pages") { json(object: "page", id: "p9") }
        @stubs.get("/v1/pages/p9") { json(**page("p9", "nine")) }
        model = Class.new(Sequel::Model(@db[:tasks]))
        rec   = model.create(Name: "nine")
        assert_equal "p9", rec.pk
        assert_equal "nine", rec[:Name]
    end

    def test_model_lookup_update_and_delete
        @stubs.get("/v1/pages/p9") { json(**page("p9", "nine")) }
        sent = []
        @stubs.patch("/v1/pages/p9") do |env|
            sent << JSON.parse(env.body)
            json(object: "page")
        end
        model = Class.new(Sequel::Model(@db[:tasks]))
        model[p9 = "p9"].update(Done: true)
        model[p9].delete
        assert_equal [{ "properties" => { "Done" => { "checkbox" => true } } },
                      { "in_trash" => true }], sent
    end

    def test_rate_limit_is_retried
        tries = 0
        @stubs.post("/v1/data_sources/#{DS_ID}/query") do
            tries += 1
            if tries == 1
                json(429, { "Retry-After" => "0" }, object: "error")
            else
                json(results: [page("p1", "a")], has_more: false)
            end
        end
        assert_equal ["a"], @db[:tasks].map(:Name)
        assert_equal 2, tries
    end

    def test_http_errors_become_database_errors
        @stubs.post("/v1/data_sources/#{DS_ID}/query") do
            json(400, code: "validation_error", message: "bad filter")
        end
        err = assert_raises(Sequel::DatabaseError) { @db[:tasks].all }
        assert_match(/validation_error: bad filter/, err.message)
    end
end
