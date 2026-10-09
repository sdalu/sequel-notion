# frozen_string_literal: true

require "test_helper"
require "faraday"
require "sequel/adapters/notion"

# Table name => data source id resolution, against a stubbed Notion
class TestRegistry < Minitest::Test
    DB_ID = "dddddddd-0000-0000-0000-000000000000"

    def connect(**)
        Sequel.connect(adapter: :notion, token: "t", test: false,
                       faraday_adapter: [:test, @stubs], **)
    end

    def setup
        @stubs    = Faraday::Adapter::Test::Stubs.new
        @searches = 0
        @stubs.post("/v1/search") do
            @searches += 1
            json(results: [source("s1", "My Tasks"), source("s2", "Électricité"),
                           { object: "page", id: "pg" }],
                 has_more: false)
        end
        @stubs.get("/v1/databases/#{DB_ID}") do
            json(data_sources: [{ id: "s3", name: "Bills" }])
        end
        @db = connect
    end

    def source(id, title)
        { object: "data_source", id: id,
          title: [{ plain_text: title }], parent: { database_id: DB_ID } }
    end

    def json(**body)
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
    end

    def test_normalize
        assert_equal "my_tasks",
                     Sequel::Notion::Registry.normalize("My Tasks")
        assert_equal "electricite", Sequel::Notion::Registry.normalize("Électricité")
    end

    def test_register_all_from_a_search
        @db.register_all_data_sources
        assert_equal %i[my_tasks electricite], @db.tables
    end

    def test_register_all_from_a_database_with_a_mapper
        @db.register_all_data_sources(database: DB_ID) do |title, _|
            "x_#{title}"
        end
        assert_equal "s3", @db.data_source_id_for(:x_Bills)
    end

    def test_search_fallback_matches_normalized_names_and_is_cached
        assert_equal "s1", @db.data_source_id_for(:my_tasks)
        assert_equal "s1", @db.data_source_id_for(:my_tasks)
        assert_equal 1, @searches
    end

    def test_uuid_table_names_pass_through
        id = "0123456789abcdef0123456789abcdef"
        assert_equal id, @db.data_source_id_for(id)
        assert_equal 0, @searches
    end

    def test_auto_register_discovers_once
        db = connect(auto_register: true)
        assert_includes db.tables, :electricite
        db.tables
        assert_equal 1, @searches
    end

    def test_unknown_table_raises
        assert_nil @db.data_source_id_for(:nothing_here)
        assert_raises(Sequel::Error) { @db[:nothing_here].all }
    end

    def test_refuses_a_name_already_bound_to_another_source
        @db.register_data_source(:a, "s1")
        @db.register_data_source(:a, "s1")
        assert_raises(Sequel::Error) { @db.register_data_source(:a, "s2") }
    end

    def test_refuses_registration_without_an_id
        assert_raises(Sequel::Error) { @db.register_data_source(:a, nil) }
    end

    def test_refuses_both_database_and_query
        assert_raises(ArgumentError) do
            @db.data_sources(database: DB_ID, query: "x")
        end
    end

    def test_refuses_a_connection_without_a_token
        db = Sequel.connect(adapter: :notion, test: false)
        assert_raises(Sequel::DatabaseConnectionError) { db.tables && db[:x].all }
    end
end
