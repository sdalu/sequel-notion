# frozen_string_literal: true

require "sequel/notion/filter_constants"
require "sequel/notion/filter_tables"
require "sequel/notion/filter_helpers"
require "sequel/notion/filter_predicates"
require "sequel/notion/filter_like_tokenizer"
require "sequel/notion/filter_like"
require "sequel/notion/filter_comparison"
require "sequel/notion/filter_nested"
require "sequel/notion/filter_negation"
require "sequel/notion/filter_nulls"
require "sequel/notion/filter_shape"

module Sequel
    module Notion
        class FilterCompiler
            include FilterConstants
            include FilterHelpers
            include FilterPredicates
            include FilterLikeTokenizer
            include FilterLike
            include FilterComparison
            include FilterNested
            include FilterNegation
            include FilterNulls
            include FilterShape

            # ----------------------------------------------------------
            # Property name resolution (rule N)
            # ----------------------------------------------------------
            #
            # Turns whatever Sequel hands us for a property reference into
            # the plain String name Notion expects.
            def self.property_name(expr)
                case expr
                when Symbol, String then return expr.to_s
                when Sequel::SQL::Identifier then return expr.value.to_s
                when Sequel::SQL::QualifiedIdentifier
                    return property_name(expr.column)
                end

                raise Sequel::Error,
                      "Unsupported property name expression: " \
                      "#{expr.inspect}"
            end

            # The compiler for one data source of a Database
            def self.for(db, ds_id)
                new(db.property_type_map(ds_id), db.rollup_kinds(ds_id))
            end

            # schema: { "Status" => "status", "Name" => "title", ... };
            # rollups: rollup name => the kind of value its function gives
            # ("number", "date", or "array" for every value)
            def initialize(schema, rollups = {})
                @prop_types = schema
                @rollups    = rollups
            end

            # The Notion filter for a WHERE: nil when every page meets it
            # (send none), NOTHING when no page does (send no request)
            def compile(expr)
                filter = compile_node(expr)
                return (filter.equal?(NOTHING) ? NOTHING : nil) if
                    constant?(filter)

                notion_shape(sql_nulls(filter))
            end

            private

            def compile_node(expr) = compile_expr(unwrap_noop(expr))

            def compile_expr(expr)
                case expr
                when Sequel::SQL::BooleanExpression then compile_boolean(expr)
                when Sequel::SQL::ComplexExpression
                    compile_comparison(expr)
                when Symbol, Sequel::SQL::Identifier,
                     Sequel::SQL::QualifiedIdentifier
                    compile_bare_column(expr)
                else
                    raise Sequel::Error, "Unsupported filter: #{expr.class}"
                end
            end

            # Sequel wraps some conditions in a one-argument NOOP
            def unwrap_noop(expr)
                while expr.is_a?(Sequel::SQL::BooleanExpression) &&
                      expr.op == :NOOP && expr.args.size == 1
                    expr = expr.args.first
                end
                expr
            end

            # AND/OR/NOT are rule N's boolean connectives; IS/IS NOT is
            # Sequel's `Sequel.expr(col => nil/true/false)` form (rule I).
            def compile_boolean(expr)
                case expr.op
                when :AND then all_of(expr.args.map { compile_node(it) })
                when :OR then any_of(expr.args.map { compile_node(it) })
                when :NOT then compile_not(expr.args.first)
                when :IS, :"IS NOT" then compile_is(expr)
                else
                    compile_comparison(expr)
                end
            end

            # Rule N's bare-column reading of NOT: `NOT checkbox_col` means
            # the checkbox is false, not "negate whatever this compiles to".
            def compile_not(inner)
                if bare_column_expr?(inner)
                    compile_bare_column(inner, value: false)
                else
                    negate(compile_node(inner))
                end
            end
        end
    end
end
