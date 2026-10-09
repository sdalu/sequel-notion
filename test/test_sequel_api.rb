# frozen_string_literal: true

require "test_helper"
require "bigdecimal"
require "faraday"
require "sequel/adapters/notion"

# Sequel API paths a SQL adapter gets for free, each one a defect found in
# review: cached loaders, extensions, models, typecasting, the trash.
class TestSequelApi < Minitest::Test
    DS_ID = "11111111-2222-3333-4444-555555555555"

    PROPS = {
        "Name" => { "type" => "title" },
        "N" => { "type" => "number" },
        "Due" => { "type" => "date" },
        "F" => { "type" => "formula" }
    }.freeze

    def setup
        @stubs = Faraday::Adapter::Test::Stubs.new
        @sent  = []
        @db    = Sequel.connect(adapter: :notion, token: "t", test: false,
                                faraday_adapter: [:test, @stubs])
        @db.register_data_source(:tasks, DS_ID)
        stub_notion
    end

    def stub_notion
        @stubs.get("/v1/data_sources/#{DS_ID}") { json(properties: PROPS) }
        @stubs.post("/v1/data_sources/#{DS_ID}/query") do
            json(results: [page("p1", "a")], has_more: false)
        end
        @stubs.get("/v1/pages/p9") { json(**page("p9", "nine")) }
        @stubs.get("/v1/pages/t1") { json(**page("t1", "gone", trash: true)) }
        @stubs.post("/v1/pages") { |env| record(env, id: "p9") }
        @stubs.patch(%r{/v1/pages/}) { |env| record(env) }
    end

    def page(id, name, trash: false, parent: DS_ID)
        { "object" => "page", "id" => id, "in_trash" => trash,
          "parent" => { "type" => "data_source_id",
                        "data_source_id" => parent },
          "properties" => {
              "Name" => { "type" => "title",
                          "title" => [{ "plain_text" => name }] }
          } }
    end

    def record(env, **reply)
        @sent << JSON.parse(env.body)
        json(object: "page", **reply)
    end

    def json(**body)
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
    end

    def model = Class.new(Sequel::Model(@db[:tasks]))

    def test_repeated_lookups_survive_sequel_loader_caching
        ds = @db[:tasks]
        4.times { assert_equal "p1", ds.first(Name: "a")[:id] }
        klass = model
        4.times { assert_equal "p9", klass["p9"].pk }
    end

    def test_explicit_primary_key_still_looks_up_the_page
        klass = model
        klass.set_primary_key :id
        assert_equal "nine", klass["p9"][:Name]
    end

    def test_symbol_model_looks_up_and_deletes_by_id
        klass    = Class.new(Sequel::Model)
        klass.db = @db
        klass.set_dataset(:tasks)
        refute klass.fast_pk_lookup_sql
        klass["p9"].delete
        assert_equal({ "in_trash" => true }, @sent.last)
    end

    def test_pagination_extension_does_not_clash
        ds = @db[:tasks].extension(:pagination)
        assert_equal ["a"], ds.map(:Name)
    end

    def test_custom_sql_is_refused
        assert_raises(Sequel::Error) { @db[:tasks].with_sql("SELECT 1").all }
    end

    # Every path that would run SQL raises Sequel::Error, not a
    # NoMethodError on a missing execute
    def test_sql_execution_is_refused
        [-> { @db.run("SELECT 1") }, -> { @db << "SELECT 1" },
         -> { @db[:tasks].truncate },
         -> { @db[:tasks].with_sql_delete("DELETE FROM t") },
         -> { @db[:tasks].with_sql_update("UPDATE t SET a = 1") },
         -> { @db[:tasks].with_sql_insert("INSERT INTO t VALUES (1)") },
         -> { @db.create_table(:x) { String :a } },
         -> { @db.drop_table(:tasks) }].each do |call|
            assert_raises(Sequel::Error) { call.call }
        end
    end

    def test_model_save_skips_computed_columns
        klass = model
        klass.plugin :skip_saving_columns
        rec = klass.load(id: "p9", Name: "x", F: 1)
        rec.Name = "z"
        rec.save
        assert_equal({ "Name" => { "title" => [{ "type" => "text",
                                                 "text" => { "content" => "z" } }] } },
                     @sent.last["properties"])
    end

    # A row reads back partial values (a date's start only, the first
    # 25 relations, plain text): save must not write them back
    def test_model_save_writes_only_changed_columns
        rec = model.load(id: "p9", Name: "x", Due: "2026-01-01", N: 1)
        rec.Name = "z"
        rec.save
        assert_equal ["Name"], @sent.last["properties"].keys
    end

    # Notion cannot sort by page id, so a model adds no primary key
    # order: paged_each streams, last needs an explicit order
    def test_model_adds_no_primary_key_order
        klass = model
        assert_equal ["a"], klass.paged_each.map(&:Name)
        error = assert_raises(Sequel::Error) { klass.last }
        assert_equal "No order specified", error.message
        assert_raises(Sequel::Error) { klass.order(:id).last }
        assert_equal "a", klass.order(:Name).last.Name
    end

    def test_model_keeps_time_and_ranges_for_dates
        klass = model
        due = Time.new(2026, 10, 9, 12, 0, 0, "+02:00")
        klass.create(Name: "x", Due: due)
        assert_equal({ "start" => due.iso8601 },
                     @sent.last.dig("properties", "Due", "date"))
    end

    def test_trashed_page_can_be_restored_by_id
        assert_equal 1, @db[:tasks].where(id: "t1").update(in_trash: false)
        assert_equal({ "properties" => {}, "in_trash" => false }, @sent.last)
    end

    def test_insert_ignores_page_columns_and_refuses_trash
        @db[:tasks].insert(id: "x", in_trash: false, Name: "n")
        assert_equal ["Name"], @sent.last["properties"].keys
        assert_raises(Sequel::Error) do
            @db[:tasks].insert(in_trash: true, Name: "n")
        end
    end

    def test_every_id_condition_applies
        assert_empty @db[:tasks].where(id: "p9").where(id: "zz").all
        assert_nil @db[:tasks].where(id: %w[p9 t1]).first(id: "zz")
    end

    def test_page_from_another_source_is_not_returned
        @stubs.get("/v1/pages/elsewhere") do
            json(**page("elsewhere", "e", parent: "other"))
        end
        assert_empty @db[:tasks].where(id: "elsewhere").all
    end

    def test_positional_insert_skips_computed_columns
        @db[:tasks].insert(["y", 2])
        assert_equal %w[Name N], @sent.last["properties"].keys
        assert_raises(Sequel::Error) { @db[:tasks].insert(%w[a b c d]) }
    end

    def test_numbers_are_sent_as_json_numbers
        @db[:tasks].insert(N: BigDecimal("1.5"))
        assert_in_delta 1.5, @sent.last.dig("properties", "N", "number")
    end

    # A model keeps an Integer it is given, as a read gives one back;
    # other values still become Floats
    def test_a_model_keeps_integers
        rec = model.new
        rec.N = 5
        assert_same 5, rec.N
        rec.N = "2.5"
        assert_in_delta 2.5, rec.N
    end

    def test_table_exists
        assert @db.table_exists?(:tasks)
        @stubs.post("/v1/search") { json(results: [], has_more: false) }
        refute @db.table_exists?(:nothing)
    end

    def test_unknown_selected_column_raises
        assert_raises(Sequel::Error) { @db[:tasks].select(:Nope).first }
    end

    def test_rollback_is_swallowed
        assert_nil(@db.transaction { raise Sequel::Rollback })
    end

    # Notion has no transactions to roll back: a test framework that
    # wraps tests in one must not be told its writes were undone
    def test_transaction_refuses_rollback_always
        assert_raises(Sequel::Error) do
            @db.transaction(rollback: :always) { @db[:tasks].insert(Name: "x") }
        end
    end

    def test_transaction_reraises_rollback_on_request
        assert_raises(Sequel::Rollback) do
            @db.transaction(rollback: :reraise) { raise Sequel::Rollback }
        end
    end

    def test_unparsable_response_is_a_database_error
        @stubs.get("/v1/pages/bad") do
            [200, { "Content-Type" => "application/json" }, "not json"]
        end
        assert_raises(Sequel::DatabaseError) { @db.notion_get_page("bad") }
    end
end
