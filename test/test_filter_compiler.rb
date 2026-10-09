# frozen_string_literal: true

require "test_helper"
require "bigdecimal"
require "sequel/notion/filter_compiler"
require "date"

class TestFilterCompiler < Minitest::Test
    PROPS = {
        "Name" => "title",
        "Done" => "checkbox",
        "N" => "number",
        "Tags" => "multi_select",
        "Due" => "date",
        "F" => "formula",
        "Url" => "url",
        "Email" => "email",
        "Select" => "select",
        "Status" => "status",
        "People" => "people",
        "Rel" => "relation",
        "UID" => "unique_id"
    }.freeze

    def setup
        @db = Sequel.mock
        @fc = Sequel::Notion::FilterCompiler.new(PROPS)
    end

    def compile(expr)
        @fc.compile(expr)
    end

    # ----------------------------------------------------------
    # Existing behaviours
    # ----------------------------------------------------------

    def test_equals
        expr = @db[:t].where(N: 5).opts[:where]
        assert_equal({ "property" => "N", "number" => { "equals" => 5 } },
                     compile(expr))
    end

    def test_less_than
        expr = (Sequel[:N] < 5)
        assert_equal({ "property" => "N", "number" => { "less_than" => 5 } },
                     compile(expr))
    end

    def test_greater_than_or_equal
        expr = (Sequel[:N] >= 5)
        assert_equal({ "property" => "N", "number" => { "greater_than_or_equal_to" => 5 } },
                     compile(expr))
    end

    def test_and
        expr = @db[:t].where(N: 1).where(Name: "x").opts[:where]
        assert_equal(
            {
                "and" => [
                    { "property" => "N", "number" => { "equals" => 1 } },
                    { "property" => "Name",
                      "rich_text" => { "equals" => "x" } }
                ]
            },
            compile(expr)
        )
    end

    def test_or
        expr = (Sequel[:N] > 1) | Sequel.expr(Name: "x")
        assert_equal(
            {
                "or" => [
                    { "property" => "N", "number" => { "greater_than" => 1 } },
                    { "property" => "Name",
                      "rich_text" => { "equals" => "x" } }
                ]
            },
            compile(expr)
        )
    end

    def test_select_equals
        expr = @db[:t].where(Select: "Yes").opts[:where]
        assert_equal({ "property" => "Select", "select" => { "equals" => "Yes" } },
                     compile(expr))
    end

    def test_status_equals
        expr = @db[:t].where(Status: "Open").opts[:where]
        assert_equal(
            { "property" => "Status",
              "status" => { "equals" => "Open" } }, compile(expr)
        )
    end

    def test_checkbox_is_true
        expr = @db[:t].where(Done: true).opts[:where]
        assert_equal({ "property" => "Done", "checkbox" => { "equals" => true } },
                     compile(expr))
    end

    # ----------------------------------------------------------
    # N: property_name
    # ----------------------------------------------------------

    def test_property_name_symbol
        assert_equal "Foo", Sequel::Notion::FilterCompiler.property_name(:Foo)
    end

    def test_property_name_string
        assert_equal "Foo", Sequel::Notion::FilterCompiler.property_name("Foo")
    end

    def test_property_name_identifier
        assert_equal "Foo", Sequel::Notion::FilterCompiler.property_name(Sequel::SQL::Identifier.new(:Foo))
    end

    def test_property_name_qualified_identifier
        qi = Sequel.qualify(:t, :Foo)
        assert_equal "Foo", Sequel::Notion::FilterCompiler.property_name(qi)
    end

    def test_property_name_unsupported_raises
        assert_raises(Sequel::Error) { Sequel::Notion::FilterCompiler.property_name(5) }
    end

    # ----------------------------------------------------------
    # U: unknown property names
    # ----------------------------------------------------------

    def test_unknown_property_raises
        expr = @db[:t].where(Bogus: 1).opts[:where]
        err = assert_raises(Sequel::Error) { compile(expr) }
        assert_match(/Bogus/, err.message)
        assert_match(/Name/, err.message)
    end

    def test_id_is_not_special
        expr = @db[:t].where(id: 5).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    # ----------------------------------------------------------
    # S: swap
    # ----------------------------------------------------------

    def test_swap_less_than
        expr = @db[:t].where { 5 < n }.opts[:where]
        fc = Sequel::Notion::FilterCompiler.new({ "n" => "number" })
        assert_equal({ "property" => "n", "number" => { "greater_than" => 5 } },
                     fc.compile(expr))
    end

    def test_swap_less_than_or_equal
        expr = @db[:t].where { 5 <= n }.opts[:where]
        fc = Sequel::Notion::FilterCompiler.new({ "n" => "number" })
        assert_equal({ "property" => "n", "number" => { "greater_than_or_equal_to" => 5 } },
                     fc.compile(expr))
    end

    # ----------------------------------------------------------
    # I: IS / IS NOT
    # ----------------------------------------------------------

    def test_is_nil
        expr = @db[:t].where(Name: nil).opts[:where]
        assert_equal(
            { "property" => "Name",
              "rich_text" => { "is_empty" => true } }, compile(expr)
        )
    end

    def test_is_not_nil
        expr = @db[:t].exclude(Name: nil).opts[:where]
        assert_equal(
            { "property" => "Name",
              "rich_text" => { "is_not_empty" => true } }, compile(expr)
        )
    end

    def test_eq_nil_simple
        expr = Sequel::SQL::BooleanExpression.new(:"=", :Name, nil)
        assert_equal(
            { "property" => "Name",
              "rich_text" => { "is_empty" => true } }, compile(expr)
        )
    end

    def test_neq_nil_simple
        expr = Sequel::SQL::BooleanExpression.new(:"!=", :Name, nil)
        assert_equal(
            { "property" => "Name",
              "rich_text" => { "is_not_empty" => true } }, compile(expr)
        )
    end

    def test_is_true_checkbox
        expr = @db[:t].where(Done: true).opts[:where]
        assert_equal({ "property" => "Done", "checkbox" => { "equals" => true } },
                     compile(expr))
    end

    def test_is_not_true_checkbox
        expr = @db[:t].exclude(Done: true).opts[:where]
        assert_equal(
            { "property" => "Done",
              "checkbox" => { "does_not_equal" => true } }, compile(expr)
        )
    end

    def test_is_other_value_raises
        expr = Sequel::SQL::BooleanExpression.new(:IS, :N, 5)
        assert_raises(Sequel::Error) { compile(expr) }
    end

    # ----------------------------------------------------------
    # B: bare column
    # ----------------------------------------------------------

    def test_bare_checkbox_column
        assert_equal({ "property" => "Done", "checkbox" => { "equals" => true } },
                     compile(:Done))
    end

    def test_bare_not_checkbox_column
        expr = Sequel::SQL::BooleanExpression.new(:NOT, :Done)
        assert_equal({ "property" => "Done", "checkbox" => { "equals" => false } },
                     compile(expr))
    end

    def test_bare_formula_column_is_its_checkbox
        assert_equal(
            { "property" => "F",
              "formula" => { "checkbox" => { "equals" => true } } },
            compile(:F)
        )
        assert_equal(
            { "property" => "F",
              "formula" => { "checkbox" => { "equals" => false } } },
            compile(@db[:t].exclude(:F).opts[:where])
        )
    end

    def test_bare_non_checkbox_raises
        assert_raises(Sequel::Error) { compile(:N) }
    end

    # ----------------------------------------------------------
    # IN / NOT IN
    # ----------------------------------------------------------

    def test_in_array
        expr = @db[:t].where(N: [1, 2, 3]).opts[:where]
        assert_equal(
            {
                "or" => [
                    { "property" => "N", "number" => { "equals" => 1 } },
                    { "property" => "N", "number" => { "equals" => 2 } },
                    { "property" => "N", "number" => { "equals" => 3 } }
                ]
            },
            compile(expr)
        )
    end

    # nil in a list means empty, as where(P: nil) does, whatever the type
    def test_in_with_nil_is_empty
        expr = @db[:t].where(N: [1, nil]).opts[:where]
        assert_equal(
            { "or" => [{ "property" => "N", "number" => { "equals" => 1 } },
                       { "property" => "N",
                         "number" => { "is_empty" => true } }] },
            compile(expr)
        )
    end

    def test_not_in_with_nil_is_not_empty
        expr = @db[:t].exclude(Tags: ["a", nil]).opts[:where]
        assert_equal(
            { "and" => [{ "property" => "Tags",
                          "multi_select" => { "does_not_contain" => "a" } },
                        { "property" => "Tags",
                          "multi_select" => { "is_not_empty" => true } }] },
            compile(expr)
        )
    end

    def test_not_in_array
        expr = @db[:t].exclude(N: [1, 2, 3]).opts[:where]
        assert_equal(
            {
                "and" => [
                    { "property" => "N",
                      "number" => { "does_not_equal" => 1 } },
                    { "property" => "N",
                      "number" => { "is_not_empty" => true } },
                    { "property" => "N",
                      "number" => { "does_not_equal" => 2 } },
                    { "property" => "N",
                      "number" => { "does_not_equal" => 3 } }
                ]
            },
            compile(expr)
        )
    end

    def test_in_multi_select_uses_contains
        expr = @db[:t].where(Tags: %w[a b]).opts[:where]
        assert_equal(
            {
                "or" => [
                    { "property" => "Tags",
                      "multi_select" => { "contains" => "a" } },
                    { "property" => "Tags",
                      "multi_select" => { "contains" => "b" } }
                ]
            },
            compile(expr)
        )
    end

    def test_equals_multi_select_uses_contains
        expr = @db[:t].where(Tags: "a").opts[:where]
        assert_equal(
            { "property" => "Tags",
              "multi_select" => { "contains" => "a" } }, compile(expr)
        )
    end

    def test_in_one_element_array_stays_wrapped
        expr = @db[:t].where(N: [1]).opts[:where]
        assert_equal(
            { "or" => [{ "property" => "N",
                         "number" => { "equals" => 1 } }] }, compile(expr)
        )
    end

    def test_in_empty_array_raises
        expr = @db[:t].where(N: []).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    def test_in_non_array_raises
        expr = @db[:t].where(N: @db[:t2].select(:x)).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    # ----------------------------------------------------------
    # L: LIKE / ILIKE
    # ----------------------------------------------------------

    def test_like_contains
        expr = @db[:t].where(Sequel.like(:Name, "%x%")).opts[:where]
        assert_equal(
            { "property" => "Name",
              "rich_text" => { "contains" => "x" } }, compile(expr)
        )
    end

    def test_like_starts_with
        expr = @db[:t].where(Sequel.like(:Name, "x%")).opts[:where]
        assert_equal(
            { "property" => "Name",
              "rich_text" => { "starts_with" => "x" } }, compile(expr)
        )
    end

    def test_like_ends_with
        expr = @db[:t].where(Sequel.like(:Name, "%x")).opts[:where]
        assert_equal(
            { "property" => "Name",
              "rich_text" => { "ends_with" => "x" } }, compile(expr)
        )
    end

    def test_like_no_wildcard_is_equals
        expr = @db[:t].where(Sequel.like(:Name, "x")).opts[:where]
        assert_equal({ "property" => "Name", "rich_text" => { "equals" => "x" } },
                     compile(expr))
    end

    def test_ilike_same_as_like
        expr = @db[:t].where(Sequel.ilike(:Name, "%x%")).opts[:where]
        assert_equal(
            { "property" => "Name",
              "rich_text" => { "contains" => "x" } }, compile(expr)
        )
    end

    def test_like_escaped_wildcards_are_literal
        expr = @db[:t].where(Sequel.like(:Name, '50\%')).opts[:where]
        assert_equal(
            { "property" => "Name",
              "rich_text" => { "equals" => "50%" } }, compile(expr)
        )
    end

    def test_like_unescaped_underscore_raises
        expr = @db[:t].where(Sequel.like(:Name, "x_y")).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    def test_like_percent_in_middle_raises
        expr = @db[:t].where(Sequel.like(:Name, "a%b")).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    def test_not_like_negates_contains
        expr = @db[:t].exclude(Sequel.like(:Name, "%x%")).opts[:where]
        assert_equal(not_empty("Name", "rich_text",
                               "does_not_contain" => "x"),
                     compile(expr))
    end

    def test_not_like_negates_equals
        expr = @db[:t].exclude(Sequel.like(:Name, "x")).opts[:where]
        assert_equal(not_empty("Name", "rich_text", "does_not_equal" => "x"),
                     compile(expr))
    end

    def test_not_like_starts_with_raises
        expr = @db[:t].exclude(Sequel.like(:Name, "x%")).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    def test_not_ilike_ends_with_raises
        expr = @db[:t].exclude(Sequel.ilike(:Name, "%x")).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    # Notion's contains on these types matches a whole option or id, so
    # a wildcard would silently turn a substring into an exact match
    def test_like_with_wildcard_on_multi_select_raises
        %i[Tags People Rel].each do |col|
            ["%x%", "x%", "%x"].each do |pattern|
                expr = @db[:t].where(Sequel.like(col, pattern)).opts[:where]
                assert_raises(Sequel::Error) { compile(expr) }
            end
        end
    end

    # A pattern made only of wildcards has no literal to equal/contain:
    # it just asks whether the property holds anything at all
    def test_like_only_wildcards_is_not_empty
        %w[%% %].each do |pattern|
            expr = @db[:t].where(Sequel.like(:Name, pattern)).opts[:where]
            assert_equal(
                { "property" => "Name",
                  "rich_text" => { "is_not_empty" => true } }, compile(expr)
            )
        end
    end

    def test_not_like_only_wildcard_is_empty
        expr = @db[:t].exclude(Sequel.like(:Name, "%")).opts[:where]
        assert_equal(
            { "property" => "Name",
              "rich_text" => { "is_empty" => true } }, compile(expr)
        )
    end

    def test_like_without_wildcard_on_multi_select_is_contains
        expr = @db[:t].where(Sequel.like(:Tags, "ruby")).opts[:where]
        assert_equal(
            { "property" => "Tags",
              "multi_select" => { "contains" => "ruby" } },
            compile(expr)
        )
    end

    # ----------------------------------------------------------
    # F: formula
    # ----------------------------------------------------------

    def test_formula_string
        expr = @db[:t].where(F: "abc").opts[:where]
        assert_equal({ "property" => "F", "formula" => { "string" => { "equals" => "abc" } } },
                     compile(expr))
    end

    def test_formula_number
        expr = (Sequel[:F] > 5)
        assert_equal({ "property" => "F", "formula" => { "number" => { "greater_than" => 5 } } },
                     compile(expr))
    end

    def test_formula_date
        d = Date.new(2026, 1, 1)
        expr = @db[:t].where(F: d).opts[:where]
        assert_equal(
            { "property" => "F",
              "formula" => { "date" => { "equals" => "2026-01-01" } } },
            compile(expr)
        )
    end

    def test_formula_date_greater_than_maps_to_after
        d = Date.new(2026, 1, 1)
        expr = Sequel::SQL::BooleanExpression.new(:>,
                                                  Sequel::SQL::Identifier.new(:F), d)
        assert_equal(
            { "property" => "F",
              "formula" => { "date" => { "after" => "2026-01-01" } } },
            compile(expr)
        )
    end

    # Sequel writes `F => true` as IS TRUE, never as =
    def test_formula_checkbox_through_is
        assert_equal(
            { "property" => "F",
              "formula" => { "checkbox" => { "equals" => true } } },
            compile(@db[:t].where(F: true).opts[:where])
        )
        assert_equal(
            { "property" => "F",
              "formula" => { "checkbox" => { "does_not_equal" => true } } },
            compile(@db[:t].exclude(F: true).opts[:where])
        )
    end

    def test_formula_nil_raises
        expr = @db[:t].where(F: nil).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    def test_formula_is_nil_raises
        expr = Sequel::SQL::BooleanExpression.new(:IS, :F, nil)
        assert_raises(Sequel::Error) { compile(expr) }
    end

    def test_formula_unsupported_value_class_raises
        expr = Sequel::SQL::BooleanExpression.new(:"=", :F, [1, 2])
        assert_raises(Sequel::Error) { compile(expr) }
    end

    # ----------------------------------------------------------
    # D: date !=
    # ----------------------------------------------------------

    def test_date_not_equal
        d = Date.new(2026, 1, 1)
        expr = @db[:t].exclude(Due: d).opts[:where]
        assert_equal(
            {
                "or" => [
                    { "property" => "Due",
                      "date" => { "before" => "2026-01-01" } },
                    { "property" => "Due",
                      "date" => { "after" => "2026-01-01" } }
                ]
            },
            compile(expr)
        )
    end

    # ----------------------------------------------------------
    # G: negate
    # ----------------------------------------------------------

    def test_negate_equals
        inner = Sequel.expr(N: 5)
        expr = Sequel::SQL::BooleanExpression.new(:NOT, inner)
        assert_equal(not_empty("N", "number", "does_not_equal" => 5),
                     compile(expr))
    end

    def test_negate_greater_than
        inner = (Sequel[:N] > 5)
        expr = Sequel::SQL::BooleanExpression.new(:NOT, inner)
        assert_equal({ "property" => "N", "number" => { "less_than_or_equal_to" => 5 } },
                     compile(expr))
    end

    def test_negate_less_than
        inner = (Sequel[:N] < 5)
        expr = Sequel::SQL::BooleanExpression.new(:NOT, inner)
        assert_equal({ "property" => "N", "number" => { "greater_than_or_equal_to" => 5 } },
                     compile(expr))
    end

    def test_negate_and_is_de_morgan_or
        inner = @db[:t].where(N: 1).where(Name: "x").opts[:where]
        expr = Sequel::SQL::BooleanExpression.new(:NOT, inner)
        assert_equal(
            {
                "or" => [
                    not_empty("N", "number", "does_not_equal" => 1),
                    not_empty("Name", "rich_text", "does_not_equal" => "x")
                ]
            },
            compile(expr)
        )
    end

    # A negated comparison under SQL's rule (E): never an empty value
    def not_empty(name, key, cond)
        { "and" => [{ "property" => name, key => cond },
                    { "property" => name, key => { "is_not_empty" => true } }] }
    end

    def test_not_equal_excludes_empty_values
        expr = @db[:t].exclude(N: 1).opts[:where]
        assert_equal(not_empty("N", "number", "does_not_equal" => 1),
                     compile(expr))
        expr = @db[:t].exclude(Tags: "a").opts[:where]
        assert_equal(not_empty("Tags", "multi_select",
                               "does_not_contain" => "a"),
                     compile(expr))
    end

    def test_checkbox_not_equal_needs_no_guard
        expr = @db[:t].exclude(Done: true).opts[:where]
        assert_equal({ "property" => "Done",
                       "checkbox" => { "does_not_equal" => true } },
                     compile(expr))
    end

    # The guard joins an enclosing "and" rather than nesting one more
    def test_guard_joins_the_enclosing_and
        expr = @db[:t].where(Name: "x").exclude(N: 1).opts[:where]
        assert_equal(
            { "and" => [{ "property" => "Name",
                          "rich_text" => { "equals" => "x" } },
                        { "property" => "N",
                          "number" => { "does_not_equal" => 1 } },
                        { "property" => "N",
                          "number" => { "is_not_empty" => true } }] },
            compile(expr)
        )
    end

    # NOT (N != 1) is N = 1: negation runs before the guard, which would
    # otherwise come back as is_empty
    def test_double_negation_is_equals
        expr = Sequel::SQL::BooleanExpression.new(:NOT, Sequel.~(N: 1))
        assert_equal({ "property" => "N", "number" => { "equals" => 1 } },
                     compile(expr))
    end

    # Notion's date has no does_not_equal (rule D)
    def test_negate_date_equals
        expr = Sequel::SQL::BooleanExpression.new(
            :NOT, Sequel.expr(Due: Date.new(2026, 1, 1))
        )
        assert_equal(
            { "or" => [{ "property" => "Due",
                         "date" => { "before" => "2026-01-01" } },
                       { "property" => "Due",
                         "date" => { "after" => "2026-01-01" } }] },
            compile(expr)
        )
    end

    def test_negate_formula_date_equals
        expr = Sequel::SQL::BooleanExpression.new(
            :NOT, Sequel.expr(F: Date.new(2026, 1, 1))
        )
        assert_equal(
            { "or" => %w[before after].map do |op|
                { "property" => "F",
                  "formula" => { "date" => { op => "2026-01-01" } } }
            end },
            compile(expr)
        )
    end

    # Notion nests and/or two levels deep at most (rule K): an and in an
    # and is spliced, a level too many is distributed, and what is
    # still deeper raises
    def test_and_inside_and_is_spliced
        inner = Sequel.|({ N: 1 }, { Done: true })
        expr  = @db[:t].where(Name: "x")
                       .where(Sequel::SQL::BooleanExpression.new(:NOT, inner))
                       .opts[:where]
        assert_equal(
            { "and" => [{ "property" => "Name",
                          "rich_text" => { "equals" => "x" } },
                        { "property" => "N",
                          "number" => { "does_not_equal" => 1 } },
                        { "property" => "N",
                          "number" => { "is_not_empty" => true } },
                        { "property" => "Done",
                          "checkbox" => { "does_not_equal" => true } }] },
            compile(expr)
        )
    end

    def leaf(name, key, cond) = { "property" => name, key => cond }

    # exclude(N: 1, Select: "a") is N != 1 OR Select != a, each guarded:
    # an or of ands inside the and, distributed into or clauses
    def test_or_of_ands_is_distributed
        expr = @db[:t].where(Name: "x").exclude(N: 1, Select: "a")
                      .opts[:where]
        n, nn = leaf("N", "number", "does_not_equal" => 1),
                leaf("N", "number", "is_not_empty" => true)
        s, sn = leaf("Select", "select", "does_not_equal" => "a"),
                leaf("Select", "select", "is_not_empty" => true)
        assert_equal(
            { "and" => [leaf("Name", "rich_text", "equals" => "x"),
                        { "or" => [n, s] }, { "or" => [n, sn] },
                        { "or" => [nn, s] }, { "or" => [nn, sn] }] },
            compile(expr)
        )
    end

    def test_three_levels_raise
        deep = Sequel.|(Sequel.&({ N: 1 }, Sequel.|({ Done: true },
                                                    { N: 3 })),
                        { N: 2 })
        expr = @db[:t].where(Name: "x").where(deep).opts[:where]
        error = assert_raises(Sequel::Error) { compile(expr) }
        assert_includes error.message, "2 levels"
    end

    # Six guarded inequalities distribute into 2**6 clauses
    def test_too_many_clauses_raise
        conds = %i[N Select Status Url Email Name].to_h { [it, "1"] }
        expr  = @db[:t].where(Done: true).exclude(conds).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    # A unique id filters on its number, given bare or as displayed
    def test_unique_id_compares_its_number
        { 62 => 62, "62" => 62, "TK-62" => 62 }.each do |given, number|
            expr = @db[:t].where(UID: given).opts[:where]
            assert_equal(leaf("UID", "unique_id", "equals" => number),
                         compile(expr))
        end
        expr = @db[:t].where(Sequel[:UID] >= "TK-3").opts[:where]
        assert_equal(leaf("UID", "unique_id",
                          "greater_than_or_equal_to" => 3), compile(expr))
    end

    # Never empty, so a negation needs no guard
    def test_unique_id_not_equal_has_no_guard
        expr = @db[:t].exclude(UID: 5).opts[:where]
        assert_equal(leaf("UID", "unique_id", "does_not_equal" => 5),
                     compile(expr))
    end

    def test_unique_id_refuses_other_values
        ["TK-", "x", 1.5].each do |bad|
            expr = @db[:t].where(UID: bad).opts[:where]
            assert_raises(Sequel::Error) { compile(expr) }
        end
        expr = @db[:t].where(Sequel.like(:UID, "TK%")).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    def test_negate_formula_leaf
        inner = Sequel.expr(F: "abc")
        expr = Sequel::SQL::BooleanExpression.new(:NOT, inner)
        assert_equal(
            { "property" => "F",
              "formula" => { "string" => { "does_not_equal" => "abc" } } },
            compile(expr)
        )
    end

    def test_negate_starts_with_raises
        inner = Sequel.like(:Name, "x%")
        expr = Sequel::SQL::BooleanExpression.new(:NOT, inner)
        assert_raises(Sequel::Error) { compile(expr) }
    end

    # ----------------------------------------------------------
    # Review regressions
    # ----------------------------------------------------------

    def test_numbers_other_than_integer_and_float_become_floats
        expr = @db[:t].where(N: BigDecimal("1.5")).opts[:where]
        assert_equal({ "property" => "N", "number" => { "equals" => 1.5 } },
                     compile(expr))
    end

    def test_non_numeric_number_value_raises
        expr = @db[:t].where(N: "abc").opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    def test_non_finite_number_value_raises
        expr = @db[:t].where(N: Float::NAN).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    # Float() accepts hex, binary and underscore-grouped strings; a
    # number filter is plain decimal text only
    def test_number_filter_refuses_non_decimal_strings
        %w[0x1A 1_000 0b11].each do |value|
            expr = @db[:t].where(N: value).opts[:where]
            assert_raises(Sequel::Error) { compile(expr) }
        end
    end

    def test_non_boolean_checkbox_value_raises
        expr = Sequel::SQL::BooleanExpression.new(:"=", :Done, "yes")
        assert_raises(Sequel::Error) { compile(expr) }
    end

    def test_noop_wrapper_is_unwrapped
        inner = @db[:t].where(N: 1).opts[:where]
        expr  = Sequel::SQL::BooleanExpression.new(:NOOP, inner)
        assert_equal compile(inner), compile(expr)
    end

    def test_column_on_the_value_side_raises
        expr = @db[:t].where(N: :Name).opts[:where]
        assert_raises(Sequel::Error) { compile(expr) }
    end

    def test_wrapped_string_literal_is_unwrapped
        expr = @db[:t].where(Name: Sequel.expr("a")).opts[:where]
        assert_equal({ "property" => "Name",
                       "rich_text" => { "equals" => "a" } }, compile(expr))
    end
end
