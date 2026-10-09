# frozen_string_literal: true

require "test_helper"
require "sequel-notion/type_map"

TM = Sequel::Notion::TypeMap

class TestTypeMap < Minitest::Test
    # ----------------------------------------------------------
    # title / rich_text
    # ----------------------------------------------------------

    def test_title_converts_to_rich_text_array
        result = TM.build_property("Hello", "title")
        assert_equal(
            { "title" => [{ "type" => "text",
                            "text" => { "content" => "Hello" } }] },
            result
        )
    end

    def test_title_nil_is_empty_array
        assert_equal({ "title" => [] }, TM.build_property(nil, "title"))
    end

    def test_title_empty_string_is_empty_array
        assert_equal({ "title" => [] }, TM.build_property("", "title"))
    end

    def test_rich_text_converts_non_string_with_to_s
        result = TM.build_property(42, "rich_text")
        assert_equal(
            { "rich_text" => [{ "type" => "text",
                                "text" => { "content" => "42" } }] },
            result
        )
    end

    def test_rich_text_nil_is_empty_array
        assert_equal({ "rich_text" => [] }, TM.build_property(nil, "rich_text"))
    end

    def test_rich_text_splits_into_2000_character_chunks
        str = "a" * 4500
        result = TM.build_property(str, "rich_text")
        chunks = result["rich_text"]

        assert_equal 3, chunks.size
        assert_equal([2000, 2000, 500], chunks.map do |c|
            c["text"]["content"].length
        end)
        assert_equal str, chunks.map { |c| c["text"]["content"] }.join
        chunks.each { |c| assert_equal "text", c["type"] }
    end

    # ----------------------------------------------------------
    # number
    # ----------------------------------------------------------

    def test_number_numeric_passes_through
        assert_equal({ "number" => 42 }, TM.build_property(42, "number"))
        assert_equal({ "number" => 3.14 }, TM.build_property(3.14, "number"))
    end

    def test_number_string_is_parsed_with_float
        assert_equal({ "number" => 3.14 }, TM.build_property("3.14", "number"))
    end

    def test_number_nil_is_nil
        assert_equal({ "number" => nil }, TM.build_property(nil, "number"))
    end

    def test_number_invalid_string_raises
        assert_raises(Sequel::Error) { TM.build_property("not-a-number", "number") }
    end

    # ----------------------------------------------------------
    # select / status
    # ----------------------------------------------------------

    def test_select_wraps_name
        assert_equal({ "select" => { "name" => "Open" } },
                     TM.build_property("Open", "select"))
    end

    def test_select_nil_is_nil
        assert_equal({ "select" => nil }, TM.build_property(nil, "select"))
    end

    def test_status_wraps_name
        assert_equal({ "status" => { "name" => "Done" } },
                     TM.build_property("Done", "status"))
    end

    def test_status_nil_is_nil
        assert_equal({ "status" => nil }, TM.build_property(nil, "status"))
    end

    # ----------------------------------------------------------
    # multi_select
    # ----------------------------------------------------------

    def test_multi_select_array
        result = TM.build_property(%w[a b], "multi_select")
        assert_equal({ "multi_select" => [{ "name" => "a" }, { "name" => "b" }] },
                     result)
    end

    def test_multi_select_single_value_is_wrapped
        result = TM.build_property("a", "multi_select")
        assert_equal({ "multi_select" => [{ "name" => "a" }] }, result)
    end

    def test_multi_select_nil_is_empty_array
        assert_equal({ "multi_select" => [] },
                     TM.build_property(nil, "multi_select"))
    end

    # ----------------------------------------------------------
    # date
    # ----------------------------------------------------------

    def test_date_with_date_object
        d = Date.new(2026, 1, 1)
        assert_equal({ "date" => { "start" => "2026-01-01" } },
                     TM.build_property(d, "date"))
    end

    def test_date_with_time_object
        t = Time.new(2026, 1, 1, 12, 0, 0, "+00:00")
        assert_equal({ "date" => { "start" => t.iso8601 } },
                     TM.build_property(t, "date"))
    end

    def test_date_with_datetime_object
        dt = DateTime.new(2026, 1, 1)
        assert_equal({ "date" => { "start" => dt.iso8601 } },
                     TM.build_property(dt, "date"))
    end

    def test_date_with_range
        range = Date.new(2026, 1, 1)..Date.new(2026, 1, 5)
        result = TM.build_property(range, "date")
        assert_equal(
            { "date" => { "start" => "2026-01-01",
                          "end" => "2026-01-05" } }, result
        )
    end

    def test_exclusive_date_range_ends_the_day_before
        range = Date.new(2026, 1, 1)...Date.new(2026, 1, 5)
        assert_equal(
            { "date" => { "start" => "2026-01-01", "end" => "2026-01-04" } },
            TM.build_property(range, "date")
        )
    end

    def test_exclusive_time_range_is_refused
        range = Time.utc(2026, 1, 1)...Time.utc(2026, 1, 5)
        assert_raises(Sequel::Error) { TM.build_property(range, "date") }
    end

    def test_date_with_string_is_unchanged
        assert_equal({ "date" => { "start" => "2026-01-01" } },
                     TM.build_property("2026-01-01", "date"))
    end

    def test_date_with_hash_symbol_keys
        hash = { start: Date.new(2026, 1, 1), end: Date.new(2026, 1, 5) }
        result = TM.build_property(hash, "date")
        assert_equal(
            { "date" => { "start" => "2026-01-01",
                          "end" => "2026-01-05" } }, result
        )
    end

    def test_date_with_hash_string_keys
        hash = { "start" => "2026-01-01", "end" => "2026-01-05" }
        result = TM.build_property(hash, "date")
        assert_equal(
            { "date" => { "start" => "2026-01-01",
                          "end" => "2026-01-05" } }, result
        )
    end

    def test_date_nil_is_nil
        assert_equal({ "date" => nil }, TM.build_property(nil, "date"))
    end

    # ----------------------------------------------------------
    # checkbox
    # ----------------------------------------------------------

    def test_checkbox_true_and_false_pass_through
        assert_equal({ "checkbox" => true },
                     TM.build_property(true, "checkbox"))
        assert_equal({ "checkbox" => false },
                     TM.build_property(false, "checkbox"))
    end

    def test_checkbox_nil_is_false
        assert_equal({ "checkbox" => false },
                     TM.build_property(nil, "checkbox"))
    end

    def test_checkbox_invalid_value_raises
        assert_raises(Sequel::Error) { TM.build_property("yes", "checkbox") }
    end

    # ----------------------------------------------------------
    # url / email / phone_number
    # ----------------------------------------------------------

    def test_url_converts_with_to_s
        assert_equal({ "url" => "https://example.com" },
                     TM.build_property("https://example.com", "url"))
    end

    def test_url_nil_is_nil
        assert_equal({ "url" => nil }, TM.build_property(nil, "url"))
    end

    def test_email_converts_with_to_s
        assert_equal({ "email" => "a@b.com" },
                     TM.build_property("a@b.com", "email"))
    end

    def test_email_nil_is_nil
        assert_equal({ "email" => nil }, TM.build_property(nil, "email"))
    end

    def test_phone_number_converts_with_to_s
        assert_equal({ "phone_number" => "555" },
                     TM.build_property("555", "phone_number"))
    end

    def test_phone_number_nil_is_nil
        assert_equal({ "phone_number" => nil },
                     TM.build_property(nil, "phone_number"))
    end

    # ----------------------------------------------------------
    # relation
    # ----------------------------------------------------------

    def test_relation_single_id
        assert_equal({ "relation" => [{ "id" => "page-1" }] },
                     TM.build_property("page-1", "relation"))
    end

    def test_relation_array_of_ids
        result = TM.build_property(%w[page-1 page-2], "relation")
        assert_equal(
            { "relation" => [{ "id" => "page-1" },
                             { "id" => "page-2" }] }, result
        )
    end

    def test_relation_nil_is_empty_array
        assert_equal({ "relation" => [] }, TM.build_property(nil, "relation"))
    end

    # ----------------------------------------------------------
    # people
    # ----------------------------------------------------------

    def test_people_single_id
        result = TM.build_property("user-1", "people")
        assert_equal({ "people" => [{ "object" => "user", "id" => "user-1" }] },
                     result)
    end

    def test_people_array_of_ids
        result = TM.build_property(%w[user-1 user-2], "people")
        assert_equal(
            { "people" => [{ "object" => "user", "id" => "user-1" },
                           { "object" => "user", "id" => "user-2" }] },
            result
        )
    end

    def test_people_nil_is_empty_array
        assert_equal({ "people" => [] }, TM.build_property(nil, "people"))
    end

    # ----------------------------------------------------------
    # files
    # ----------------------------------------------------------

    def test_files_with_notion_file
        file = Sequel::Notion::File.external("https://example.com/doc.pdf")
        result = TM.build_property(file, "files")
        assert_equal({ "files" => [file.to_notion] }, result)
    end

    def test_files_with_url_string
        result = TM.build_property("https://example.com/doc.pdf", "files")
        expected = Sequel::Notion::File.external("https://example.com/doc.pdf").to_notion
        assert_equal({ "files" => [expected] }, result)
    end

    def test_files_with_array
        file = Sequel::Notion::File.external("https://example.com/a.pdf")
        result = TM.build_property([file, "https://example.com/b.pdf"], "files")
        assert_equal 2, result["files"].size
    end

    def test_files_nil_is_empty_array
        assert_equal({ "files" => [] }, TM.build_property(nil, "files"))
    end

    # ----------------------------------------------------------
    # read-only / unsupported types
    # ----------------------------------------------------------

    def test_read_only_type_raises
        %w[formula rollup created_time last_edited_time created_by last_edited_by
           unique_id button verification].each do |type|
            assert_raises(Sequel::Error) { TM.build_property("x", type) }
        end
    end

    def test_unsupported_type_raises
        assert_raises(Sequel::Error) { TM.build_property("x", "no_such_type") }
    end

    # ----------------------------------------------------------
    # row_to_properties
    # ----------------------------------------------------------

    def test_row_to_properties_missing_prop_type_raises
        assert_raises(Sequel::Error) { TM.row_to_properties({ "Ghost" => 1 }, {}) }
    end

    def test_row_to_properties_mixes_title_status_date_and_relation
        prop_types = {
            "Name" => "title",
            "Status" => "status",
            "Due" => "date",
            "Parent" => "relation"
        }
        row = {
            Name: "Launch",
            Status: "In Progress",
            Due: Date.new(2026, 1, 1),
            Parent: "page-123"
        }

        result = TM.row_to_properties(row, prop_types)

        assert_equal(
            {
                "Name" => { "title" => [{ "type" => "text",
                                          "text" => { "content" => "Launch" } }] },
                "Status" => { "status" => { "name" => "In Progress" } },
                "Due" => { "date" => { "start" => "2026-01-01" } },
                "Parent" => { "relation" => [{ "id" => "page-123" }] }
            },
            result
        )
    end
end
