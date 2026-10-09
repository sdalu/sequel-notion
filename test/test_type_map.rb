# frozen_string_literal: true

require "test_helper"
require "sequel/notion/type_map"

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

    # Notion counts UTF-16 units: an emoji is two, and is never cut
    def test_rich_text_runs_hold_2000_utf16_units
        str    = "#{"a" * 1999}😀#{"😀" * 1500}"
        chunks = TM.build_property(str, "rich_text")["rich_text"]
                   .map { it["text"]["content"] }

        assert_equal str, chunks.join
        assert_equal([1999, 2000, 1002],
                     chunks.map { it.encode("UTF-16LE").bytesize / 2 })
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

    # Float parses "1e400" to Infinity rather than raising
    def test_number_string_overflow_raises
        assert_raises(Sequel::Error) { TM.build_property("1e400", "number") }
    end

    # Float() accepts hex, binary and underscore-grouped strings; a
    # number property is plain decimal text only
    def test_number_string_must_be_decimal
        %w[0x1A 1_000 0b11].each do |value|
            assert_raises(Sequel::Error) { TM.build_property(value, "number") }
        end
        [" 5 ", "3.14", "-2", "1e3"].each do |value|
            assert_kind_of Numeric, TM.build_property(value, "number")["number"]
        end
    end

    def test_number_refuses_nan_and_infinity_naming_the_property
        [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |value|
            error = assert_raises(Sequel::Error) do
                TM.row_to_properties({ N: value }, { "N" => "number" })
            end
            assert_includes error.message, '"N"'
        end
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

    # Notion needs a start; an endless range is an open end
    def test_beginless_date_range_is_refused
        error = assert_raises(Sequel::Error) do
            TM.row_to_properties({ Due: ..Date.new(2026, 1, 5) },
                                 { "Due" => "date" })
        end
        assert_includes error.message, '"Due"'
        assert_equal({ "date" => { "start" => "2026-01-01", "end" => nil } },
                     TM.build_property(Date.new(2026, 1, 1).., "date"))
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

    # As for a Range: Notion's date needs a start; nil clears it
    def test_date_hash_needs_a_start
        assert_raises(Sequel::Error) do
            TM.build_property({ end: "2026-01-31" }, "date")
        end
        assert_raises(Sequel::Error) { TM.build_property({}, "date") }
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

    def test_file_url_with_a_space_raises_naming_the_property
        error = assert_raises(Sequel::Error) do
            TM.row_to_properties({ F: "https://ex.com/a b.pdf" },
                                 { "F" => "files" })
        end
        assert_includes error.message, '"F"'
    end

    # The name is the segment decoded; one that does not decode is kept
    def test_file_name_is_the_decoded_path_segment
        {
            "https://x.test/d/a%20b+c%C3%A9.pdf" => "a b+cé.pdf",
            "https://x.test/plain.pdf" => "plain.pdf",
            "https://x.test/100%25.pdf" => "100%.pdf",
            "https://x.test/bad%FF.pdf" => "bad%FF.pdf"
        }.each do |url, name|
            assert_equal name,
                         Sequel::Notion::File.external(url).to_notion["name"]
        end
    end

    def test_file_url_with_no_path_is_named_by_the_url
        %w[https://ex.com/ https://ex.com].each do |url|
            name = Sequel::Notion::File.external(url).to_notion["name"]
            assert_equal url, name
        end
    end

    def test_files_nil_is_empty_array
        assert_equal({ "files" => [] }, TM.build_property(nil, "files"))
    end

    # A type Notion added after this adapter (e.g. file_upload) must not
    # blow up reading the page; round-trip it opaquely instead
    def test_unknown_file_type_round_trips
        obj = { "type" => "file_upload", "name" => "x.pdf",
                "file_upload" => { "id" => "u1" } }
        files = Sequel::Notion::File.from_notion_property({ "files" => [obj] })

        assert_equal 1, files.size
        assert_equal :file_upload, files.first.type
        assert_equal obj, files.first.to_notion
    end

    # Two uploads have no URL; only their raw hashes tell them apart
    def test_unknown_file_types_differ_by_raw
        a, b = Sequel::Notion::File.from_notion_property(
            { "files" => [{ "type" => "file_upload", "file_upload" => { "id" => "u1" } },
                          { "type" => "file_upload", "file_upload" => { "id" => "u2" } }] }
        )
        refute_equal a, b
        assert_equal 2, [a, b].uniq.size
    end

    # File is public API: a mistyped keyword must not vanish
    def test_file_refuses_an_unknown_keyword
        assert_raises(ArgumentError) do
            Sequel::Notion::File.new(url: "https://x.org/a", expiry: "t")
        end
    end

    def test_file_object_without_a_type_raises
        assert_raises(Sequel::Error) do
            Sequel::Notion::File.from_notion({ "name" => "x.pdf" })
        end
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

    # A Hash is no list of names or ids
    def test_hash_to_a_list_property_raises
        %w[multi_select relation people].each do |type|
            assert_raises(Sequel::Error) do
                TM.build_property({ a: "b" }, type)
            end
        end
    end
end
