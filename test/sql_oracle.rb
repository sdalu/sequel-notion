# frozen_string_literal: true

require "faraday"
require "date"
require "set"
require "sequel/adapters/notion"

# The same rows in a stubbed Notion, which filters and sorts as Notion
# does, and in an in-memory SQLite database, so that a Sequel query can
# be run on both and the results compared. Mixed into the oracle tests.
module SqlOracle
    TASKS    = "22222222-0000-0000-0000-000000000001"
    PROJECTS = "22222222-0000-0000-0000-000000000002"
    TYPES    = {
        TASKS => { "Name" => "title", "N" => "number", "Proj" => "relation",
                   "Due" => "date", "Kind" => "select",
                   "Done" => "checkbox" },
        PROJECTS => { "Name" => "title", "Budget" => "number" }
    }.freeze

    # ----------------------------------------------------------
    # Data
    # ----------------------------------------------------------

    def dataset(rnd)
        projects = Array.new(rnd.rand(1..4)) do |i|
            { id: uuid("bbbbbbbb", i), Name: %w[Alpha Beta Alpha][i % 3],
              Budget: [nil, 10, 20, 10].sample(random: rnd) }
        end
        tasks = Array.new(rnd.rand(0..9)) do |i|
            { id: uuid("cccccccc", i), Name: %w[a b c a].sample(random: rnd),
              N: [nil, 0, 1, 2, 2, 3, -1].sample(random: rnd),
              Proj: [nil, *projects.map { it[:id] }].sample(random: rnd),
              Due: DATES.sample(random: rnd),
              Kind: [nil, "x", "y", "x", "z"].sample(random: rnd),
              Done: [true, false].sample(random: rnd) }
        end
        { tasks:, projects: }
    end

    DATES = [nil, Date.new(2026, 1, 1), Date.new(2026, 1, 2),
             Date.new(2026, 1, 2), Date.new(2026, 2, 1)].freeze

    def uuid(prefix, index) = format("#{prefix}-0000-0000-0000-%012d", index)

    def sqlite(data)
        db = Sequel.sqlite
        db.create_table(:tasks) do
            String :id
            String :Name
            Integer :N
            String :Proj
            Date :Due
            String :Kind
            TrueClass :Done
        end
        db.create_table(:projects) do
            String :id
            String :Name
            Integer :Budget
        end
        data.each { |table, rows| db[table].multi_insert(rows) }
        { tasks: db[:tasks], projects: db[:projects] }
    end

    def notion(data)
        stubs = Faraday::Adapter::Test::Stubs.new
        db    = Sequel.connect(adapter: :notion, token: "t", test: false,
                               faraday_adapter: [:test, stubs])
        { tasks: TASKS, projects: PROJECTS }.each do |table, id|
            db.register_data_source(table, id)
            serve(stubs, id, data[table])
        end
        { tasks: db[:tasks].client_side, projects: db[:projects].client_side }
    end

    # ----------------------------------------------------------
    # A Notion that filters and sorts
    # ----------------------------------------------------------

    def serve(stubs, id, rows)
        types = TYPES[id]
        serve_pages(stubs, id, rows, types)
        props = types.transform_values { { "type" => it } }
        stubs.get("/v1/data_sources/#{id}") { json(properties: props) }
        stubs.post("/v1/data_sources/#{id}/query") do |env|
            body = JSON.parse(env.body)
            kept = rows.select { matches?(it, body["filter"]) }
            kept = sorted_pages(kept, body["sorts"])
            json(results: kept.map { page(it, types) }, has_more: false)
        end
    end

    # Each page by id, Notion's 404 for any other, and updates (each
    # answered with a page, whatever the change)
    def serve_pages(stubs, id, rows, types)
        rows.each do |row|
            stubs.get("/v1/pages/#{row[:id].delete("-")}") do
                json(**page(row, types).merge(
                    "parent" => { "type" => "data_source_id",
                                  "data_source_id" => id }
                ))
            end
        end
        return unless id == PROJECTS

        stubs.patch(%r{\A/v1/pages/}) { json(object: "page", id: "x") }
        stubs.get(%r{\A/v1/pages/}) do
            [404, { "Content-Type" => "application/json" },
             JSON.generate(object: "error", status: 404,
                           code: "object_not_found", message: "no page")]
        end
    end

    def json(**body)
        [200, { "Content-Type" => "application/json" }, JSON.generate(body)]
    end

    def page(row, types)
        { "object" => "page", "id" => row[:id], "in_trash" => false,
          "properties" => types.to_h do |name, type|
              [name, prop(type, row[name.to_sym])]
          end }
    end

    def prop(type, value)
        case type
        when "title"
            { "type" => type, type => [{ "plain_text" => value.to_s }] }
        when "relation"
            { "type" => type,
              type => Array(value).map { { "id" => it } }, "has_more" => false }
        when "date"
            { "type" => type,
              type => value && { "start" => value.iso8601, "end" => nil } }
        when "select"
            { "type" => type, type => value && { "name" => value } }
        else { "type" => type, type => value }
        end
    end

    # Notion's semantics: an empty value matches does_not_equal and
    # is_empty, and fails every other comparison
    def matches?(row, filter)
        return true if filter.nil?
        return filter["and"].all? { matches?(row, it) } if filter["and"]
        return filter["or"].any? { matches?(row, it) } if filter["or"]

        value   = row[filter["property"].to_sym]
        value   = value.iso8601 if value.is_a?(Date)
        op, arg = filter.except("property").values.first.first
        compare(DATE_OPS.fetch(op, op), value, arg)
    end

    def compare(op, value, arg)
        case op
        when "starts_with" then !value.nil? && value.start_with?(arg)
        when "ends_with" then !value.nil? && value.end_with?(arg)
        when "contains" then !value.nil? && value.include?(arg)
        when "does_not_contain" then value.nil? || !value.include?(arg)
        when "is_empty" then value.nil?
        when "is_not_empty" then !value.nil?
        when "does_not_equal" then value != arg
        else
            return false if value.nil?

            value.public_send(OPS.fetch(op) { raise "stub filter: #{op}" },
                              arg)
        end
    end

    OPS = { "equals" => :==, "greater_than" => :>, "less_than" => :<,
            "greater_than_or_equal_to" => :>=,
            "less_than_or_equal_to" => :<= }.freeze

    # A date's operators, on ISO 8601 strings, which order as dates do
    DATE_OPS = { "before" => "less_than", "after" => "greater_than",
                 "on_or_before" => "less_than_or_equal_to",
                 "on_or_after" => "greater_than_or_equal_to" }.freeze

    # Empty values last, in both directions
    def sorted_pages(rows, sorts)
        return rows if sorts.nil? || sorts.empty?

        rows.sort do |a, b|
            sorts.lazy.map { sort_compare(a, b, it) }.find(&:nonzero?) || 0
        end
    end

    def sort_compare(a, b, sort)
        x, y = [a, b].map { it[sort["property"].to_sym] }
                     .map { [true, false].include?(it) ? (it ? 1 : 0) : it }
        return 0 if x.nil? && y.nil?
        return 1 if x.nil?
        return -1 if y.nil?

        sort["direction"] == "descending" ? y <=> x : x <=> y
    end

    # ----------------------------------------------------------
    # Comparing
    # ----------------------------------------------------------

    def normal(value)
        case value
        when Array then value.map { normal(it) }
        when Set then value.to_a.map { normal(it) }.sort_by(&:inspect)
        when Hash then value.to_h { |k, v| [normal(k), normal(v)] }
        when Numeric then value.to_f.round(9)
        when Date then value.iso8601
        else value
        end
    end

    def sorted(value)
        value.is_a?(Array) ? value.sort_by(&:inspect) : value
    end
end
