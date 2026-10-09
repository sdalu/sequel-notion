# frozen_string_literal: true

require "test_helper"
require "faraday"
require "sequel/adapters/notion"

# Joins between data sources, matched in Ruby: each side is queried with
# the conditions that test it alone, and a relation matches the pages it
# lists
class TestJoins < Minitest::Test
    TASKS    = "11111111-0000-0000-0000-000000000001"
    PROJECTS = "11111111-0000-0000-0000-000000000002"
    P1       = "aaaaaaaa-0000-0000-0000-000000000001"
    P2       = "aaaaaaaa-0000-0000-0000-000000000002"

    def setup
        @stubs = Faraday::Adapter::Test::Stubs.new
        @sent  = Hash.new { |h, k| h[k] = [] }
        @db    = Sequel.connect(adapter: :notion, token: "t", test: false,
                                faraday_adapter: [:test, @stubs])
        @db.register_data_source(:tasks, TASKS)
        @db.register_data_source(:projects, PROJECTS)
        source(TASKS, { "Name" => "title", "N" => "number",
                        "Proj" => "relation" },
               [["t1", { "Name" => "a", "N" => 1, "Proj" => [P1] }],
                ["t2", { "Name" => "b", "N" => 2, "Proj" => [P1, P2] }],
                ["t3", { "Name" => "c", "N" => 3, "Proj" => [] }]])
        source(PROJECTS, { "Name" => "title", "Budget" => "number" },
               [[P1, { "Name" => "Alpha", "Budget" => 10 }],
                [P2, { "Name" => "Beta", "Budget" => 20 }]])
    end

    def json(**body)
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
    end

    def source(id, types, pages)
        props = types.transform_values { { "type" => it } }
        @stubs.get("/v1/data_sources/#{id}") { json(properties: props) }
        @stubs.post("/v1/data_sources/#{id}/query") do |env|
            filter = JSON.parse(env.body)["filter"]
            @sent[id] << filter
            kept = pages.select { |_, values| matches?(values, filter) }
            json(results: kept.map { |pid, values| page(pid, types, values) },
                 has_more: false)
        end
    end

    # The few filters these tests send, as Notion would apply them
    def matches?(values, filter)
        return true if filter.nil?
        return filter["and"].all? { matches?(values, it) } if filter["and"]
        return filter["or"].any? { matches?(values, it) } if filter["or"]

        value   = values[filter["property"]]
        op, arg = filter.except("property").values.first.first
        case op
        when "equals" then value == arg
        when "greater_than" then !value.nil? && value > arg
        when "is_empty" then value.nil?
        else raise "stub filter: #{op}"
        end
    end

    def page(id, types, values)
        { "object" => "page", "id" => id, "in_trash" => false,
          "properties" => values.to_h { |name, v| [name, prop(types[name], v)] } }
    end

    def prop(type, value)
        case type
        when "title" then { "type" => type, type => [{ "plain_text" => value }] }
        when "relation" then { "type" => type, type => value.map { { "id" => it } } }
        else { "type" => type, type => value }
        end
    end

    def tasks = @db[:tasks].client_side

    def names(rows) = rows.map { it.values_at(:task, :project) }

    def test_inner_join_through_a_relation
        rows = tasks.join(:projects, id: :Proj)
                    .select(Sequel[:tasks][:Name].as(:task),
                            Sequel[:projects][:Name].as(:project))
                    .order(:task, :project).all
        assert_equal [%w[a Alpha], %w[b Alpha], %w[b Beta]], names(rows)
    end

    def test_left_join_keeps_unmatched_rows
        rows = tasks.left_join(:projects, id: :Proj)
                    .select(Sequel[:tasks][:Name].as(:task),
                            Sequel[:projects][:Name].as(:project))
                    .order(:task, :project).all
        assert_equal [%w[a Alpha], %w[b Alpha], %w[b Beta], ["c", nil]],
                     names(rows)
    end

    # Each condition testing one side runs in Notion, on that side
    def test_where_runs_on_each_side
        tasks.join(Sequel[:projects].as(:p), id: :Proj)
             .where(Sequel[:p][:Budget] > 15).where(Sequel[:tasks][:N] => 2).all
        assert_equal [{ "property" => "N", "number" => { "equals" => 2 } }],
                     @sent[TASKS]
        assert_equal [{ "property" => "Budget",
                        "number" => { "greater_than" => 15 } }],
                     @sent[PROJECTS]
    end

    def test_unqualified_columns_resolve_by_schema
        rows = tasks.join(:projects, id: :Proj).select(:N, :Budget)
                    .order(:N, :Budget).all
        assert_equal [{ N: 1, Budget: 10 }, { N: 2, Budget: 10 },
                      { N: 2, Budget: 20 }], rows
        assert_equal 3, tasks.join(:projects, id: :Proj).count
        assert_equal 40, tasks.join(:projects, id: :Proj).sum(:Budget)
    end

    def test_without_select_the_later_table_wins_a_name
        row = tasks.join(:projects, id: :Proj).order(:N).first
        assert_equal "Alpha", row[:Name]
        assert_equal 1, row[:N]
    end

    # Qualified columns keep their table through aggregates and groups
    def test_aggregates_and_groups_of_qualified_columns
        joined = tasks.join(:projects, id: :Proj)
        assert_equal 40, joined.sum(Sequel[:projects][:Budget])
        assert_equal [{ Name: "Alpha", n: 2 }, { Name: "Beta", n: 1 }],
                     joined.group(Sequel[:projects][:Name])
                           .select(Sequel[:projects][:Name]) { count.function.*.as(:n) }
                           .order(:Name).all
    end

    def test_unsupported_joins_raise
        assert_raises(Sequel::Error) { tasks.join(:projects, id: :Proj).select(:Name).all }
        assert_raises(Sequel::Error) do
            tasks.join(:projects, id: :Proj)
                 .where(Sequel[:tasks][:N] => Sequel[:projects][:Budget]).all
        end
        assert_raises(Sequel::Error) { tasks.cross_join(:projects).all }
        assert_raises(Sequel::Error) { tasks.join(:projects, [:Name]).all }
    end

    # WHERE runs after a left join, as in SQL: a row whose partner fails
    # it is dropped, not kept with an empty right side
    def test_left_join_where_on_the_joined_table
        rows = tasks.left_join(:projects, id: :Proj)
                    .where(Sequel[:projects][:Budget] => 20)
                    .select(Sequel[:tasks][:Name].as(:task),
                            Sequel[:projects][:Name].as(:project))
                    .order(:task, :project).all
        assert_equal [%w[b Beta]], names(rows)
    end

    # A row with no partner is kept when its empty side passes
    def test_left_join_where_empty_on_the_joined_table
        rows = tasks.left_join(:projects, id: :Proj)
                    .where(Sequel[:projects][:Budget] => nil)
                    .select(Sequel[:tasks][:Name].as(:task),
                            Sequel[:projects][:Name].as(:project))
                    .order(:task).all
        assert_equal [["c", nil]], names(rows)
    end
end
