# frozen_string_literal: true

require "test_helper"
require "sequel/adapters/notion"

# Notion page → row, one property type at a time
class TestPageToRow < Minitest::Test
    TM = Sequel::Notion::TypeMap

    def read(type, value) = TM.extract_value("type" => type, type => value)

    def test_page_columns_and_property_names
        page = { "id" => "p1", "in_trash" => false,
                 "properties" => { "N" => { "type" => "number",
                                            "number" => 3 } } }
        assert_equal({ id: "p1", in_trash: false, N: 3 }, TM.page_to_row(page))
    end

    def test_plain_types
        assert_equal "ab", read("title", [{ "plain_text" => "a" },
                                          { "plain_text" => "b" }])
        assert_equal "x", read("select", { "name" => "x" })
        assert_equal %w[a b], read("multi_select", [{ "name" => "a" },
                                                    { "name" => "b" }])
        assert_equal %w[u1], read("people", [{ "id" => "u1" }])
        assert_equal %w[r1], read("relation", [{ "id" => "r1" }])
        assert read("checkbox", true)
        assert_nil read("select", nil)
    end

    def test_date_without_end_is_its_start
        assert_equal "2026-01-01", read("date", { "start" => "2026-01-01",
                                                  "end" => nil })
        assert_nil read("date", nil)
    end

    # A date range reads back as the Range writes take
    def test_date_range_is_a_range
        assert_equal "2026-01-01".."2026-01-31",
                     read("date", { "start" => "2026-01-01",
                                    "end" => "2026-01-31" })
    end

    def test_formula_date_range_is_a_range
        value = { "type" => "date",
                  "date" => { "start" => "2026-01-01", "end" => "2026-01-02" } }
        assert_equal "2026-01-01".."2026-01-02", read("formula", value)
        assert_equal "x", read("formula", { "type" => "string", "string" => "x" })
    end

    # A rollup reads as its value: a number, or an Array of the
    # rolled-up values, each read as its own type
    def test_rollup_is_its_value
        assert_equal 7, read("rollup", { "type" => "number", "number" => 7,
                                         "function" => "sum" })
        dates = [{ "type" => "date",
                   "date" => { "start" => "2026-01-01", "end" => "2026-01-03" } },
                 { "type" => "date",
                   "date" => { "start" => "2026-02-01", "end" => nil } }]
        assert_equal ["2026-01-01".."2026-01-03", "2026-02-01"],
                     read("rollup", { "type" => "array", "array" => dates })
        titles = [{ "type" => "title", "title" => [{ "plain_text" => "x" }] }]
        assert_equal ["x"], read("rollup", { "type" => "array",
                                             "array" => titles })
        assert_nil read("rollup", nil)
    end

    # As Notion displays it
    def test_unique_id_is_prefix_and_number
        assert_equal "TK-62", read("unique_id", { "prefix" => "TK",
                                                  "number" => 62 })
        assert_equal "7", read("unique_id", { "prefix" => nil, "number" => 7 })
        assert_nil read("unique_id", { "prefix" => "TK", "number" => nil })
    end
end
