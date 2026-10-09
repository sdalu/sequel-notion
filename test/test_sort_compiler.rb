# frozen_string_literal: true

require "test_helper"
require "sequel/notion/sort_compiler"

class TestSortCompiler < Minitest::Test
    def setup
        @db = Sequel.mock
    end

    def compile(order)
        Sequel::Notion::SortCompiler.compile(order)
    end

    def test_plain_symbol_ascending
        order = @db[:t].order(:Name).opts[:order]
        assert_equal([{ "property" => "Name", "direction" => "ascending" }],
                     compile(order))
    end

    def test_plain_string_ascending
        assert_equal([{ "property" => "Name", "direction" => "ascending" }],
                     compile(["Name"]))
    end

    def test_identifier_ascending
        order = @db[:t].order(Sequel.identifier(:Name)).opts[:order]
        assert_equal([{ "property" => "Name", "direction" => "ascending" }],
                     compile(order))
    end

    def test_ordered_expression_descending
        order = @db[:t].order(Sequel.desc(:Name)).opts[:order]
        assert_equal([{ "property" => "Name", "direction" => "descending" }],
                     compile(order))
    end

    def test_ordered_expression_ascending_explicit
        order = @db[:t].order(Sequel.asc(:Name)).opts[:order]
        assert_equal([{ "property" => "Name", "direction" => "ascending" }],
                     compile(order))
    end

    def test_qualified_identifier_in_ordered_expression
        order = @db[:t].order(Sequel.desc(Sequel.qualify(:t,
                                                         :Name))).opts[:order]
        assert_equal([{ "property" => "Name", "direction" => "descending" }],
                     compile(order))
    end

    def test_plain_qualified_identifier
        order = @db[:t].order(Sequel.qualify(:t, :Name)).opts[:order]
        assert_equal([{ "property" => "Name", "direction" => "ascending" }],
                     compile(order))
    end

    def test_multiple_clauses
        order = @db[:t].order(:A, Sequel.desc(:B)).opts[:order]
        assert_equal(
            [
                { "property" => "A", "direction" => "ascending" },
                { "property" => "B", "direction" => "descending" }
            ],
            compile(order)
        )
    end

    def test_unsupported_order_expression_raises
        assert_raises(Sequel::Error) { compile([5]) }
    end
end
