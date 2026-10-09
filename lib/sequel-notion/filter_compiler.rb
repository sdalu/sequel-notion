# frozen_string_literal: true

module Sequel
  module Notion
    class FilterCompiler
      def initialize(schema)
        # schema = { "Status" => "status", "Name" => "title", ... }
        @prop_types = schema
      end

      def compile(expr)
        case expr
        when Sequel::SQL::BooleanExpression
          compile_boolean(expr)
        when Sequel::SQL::ComplexExpression
          compile_comparison(expr)
        else
          raise Sequel::Error, "Unsupported filter expression: #{expr.class}"
        end
      end

      private

      def compile_boolean(expr)
        case expr.op
        when :AND
          { "and" => expr.args.map { |a| compile(a) } }
        when :OR
          { "or" => expr.args.map { |a| compile(a) } }
        when :NOT
          negate(compile(expr.args.first))

        # ── IS NULL: Sequel.expr(col => nil) ─────────────
        when :IS
          compile_null_check(expr, empty: true)

        # ── IS NOT NULL: ~Sequel.expr(col => nil) ────────
        when :ISNOT, :"IS NOT"
          compile_null_check(expr, empty: false)

        else
          compile_comparison(expr)
        end
      end

      OPERATOR_MAP = {
        :"="  => "equals",
        :"!=" => "does_not_equal",
        :>    => "greater_than",
        :<    => "less_than",
        :>=   => "greater_than_or_equal_to",
        :<=   => "less_than_or_equal_to",
        :LIKE => "contains",
      }.freeze

      FILTER_TYPE_KEY = {
        "title"            => "rich_text",
        "rich_text"        => "rich_text",
        "number"           => "number",
        "select"           => "select",
        "multi_select"     => "multi_select",
        "status"           => "status",
        "date"             => "date",
        "checkbox"         => "checkbox",
        "url"              => "url",
        "email"            => "email",
        "phone_number"     => "phone_number",
        "people"           => "people",
        "relation"         => "relation",
        "created_time"     => "date",
        "last_edited_time" => "date",
        "formula"          => "formula",
        "files"            => "files",
      }.freeze

      SUPPORTED_OPS = {
        "rich_text"    => %w[equals does_not_equal contains does_not_contain
                             starts_with ends_with is_empty is_not_empty],
        "number"       => %w[equals does_not_equal greater_than less_than
                             greater_than_or_equal_to less_than_or_equal_to
                             is_empty is_not_empty],
        "select"       => %w[equals does_not_equal is_empty is_not_empty],
        "multi_select" => %w[contains does_not_contain is_empty is_not_empty],
        "status"       => %w[equals does_not_equal is_empty is_not_empty],
        "date"         => %w[equals before after on_or_before on_or_after
                             is_empty is_not_empty],
        "checkbox"     => %w[equals does_not_equal],
        "url"          => %w[equals does_not_equal contains does_not_contain
                             starts_with ends_with is_empty is_not_empty],
        "email"        => %w[equals does_not_equal contains does_not_contain
                             starts_with ends_with is_empty is_not_empty],
        "phone_number" => %w[equals does_not_equal contains does_not_contain
                             starts_with ends_with is_empty is_not_empty],
        "people"       => %w[contains does_not_contain is_empty is_not_empty],
        "relation"     => %w[contains does_not_contain is_empty is_not_empty],
        "files"        => %w[is_empty is_not_empty],
        "formula"      => %w[equals does_not_equal contains does_not_contain
                             greater_than less_than greater_than_or_equal_to
                             less_than_or_equal_to is_empty is_not_empty],
      }.freeze

      DATE_OPERATOR_MAP = {
        "greater_than"             => "after",
        "less_than"                => "before",
        "greater_than_or_equal_to" => "on_or_after",
        "less_than_or_equal_to"    => "on_or_before",
      }.freeze

      # ----------------------------------------------------------
      # Null / empty check  →  is_empty / is_not_empty
      # ----------------------------------------------------------

      def compile_null_check(expr, empty:)
        # expr.args = [column_identifier, nil]
        prop_name = expr.args[0].to_s

        notion_type = @prop_types[prop_name]
        unless notion_type
          raise Sequel::Error,
                "Unknown property '#{prop_name}'. " \
                "Available: #{@prop_types.keys.join(", ")}"
        end

        filter_key = FILTER_TYPE_KEY[notion_type]
        unless filter_key
          raise Sequel::Error,
                "Property '#{prop_name}' (type: #{notion_type}) is not filterable"
        end

        op = empty ? "is_empty" : "is_not_empty"

        unless SUPPORTED_OPS.fetch(filter_key, []).include?(op)
          raise Sequel::Error,
                "Operator '#{op}' not supported for " \
                "#{filter_key} property '#{prop_name}'"
        end

        {
          "property" => prop_name,
          filter_key => { op => true }
        }
      end

      # ----------------------------------------------------------
      # Standard comparison
      # ----------------------------------------------------------

      def compile_comparison(expr)
        prop_name  = expr.args[0].to_s
        value      = expr.args[1]
        sequel_op  = expr.op

        # ── Handle nil value in = / != operators ─────────
        # .where(col: nil)   → Sequel generates :(= col nil) on some paths
        # .exclude(col: nil) → Sequel generates :(!= col nil)
        if value.nil? && %i[= !=].include?(sequel_op)
          return compile_null_check_simple(prop_name, empty: sequel_op == :"=")
        end

        notion_op = OPERATOR_MAP[sequel_op]
        raise Sequel::Error, "Unsupported operator: #{sequel_op}" unless notion_op

        notion_type = @prop_types[prop_name]
        unless notion_type
          raise Sequel::Error,
                "Unknown property '#{prop_name}'. " \
                "Available: #{@prop_types.keys.join(", ")}"
        end

        filter_key = FILTER_TYPE_KEY[notion_type]
        unless filter_key
          raise Sequel::Error,
                "Property '#{prop_name}' (type: #{notion_type}) is not filterable"
        end

        if filter_key == "date" && DATE_OPERATOR_MAP.key?(notion_op)
          notion_op = DATE_OPERATOR_MAP[notion_op]
        end

        unless SUPPORTED_OPS.fetch(filter_key, []).include?(notion_op)
          raise Sequel::Error,
                "Operator '#{notion_op}' not supported for " \
                "#{filter_key} property '#{prop_name}'"
        end

        coerced = coerce_value(value, filter_key)

        {
          "property" => prop_name,
          filter_key => { notion_op => coerced }
        }
      end

      # Nil passed directly in = / != (not via IS / IS NOT)
      def compile_null_check_simple(prop_name, empty:)
        notion_type = @prop_types[prop_name]
        unless notion_type
          raise Sequel::Error,
                "Unknown property '#{prop_name}'. " \
                "Available: #{@prop_types.keys.join(", ")}"
        end

        filter_key = FILTER_TYPE_KEY[notion_type]
        unless filter_key
          raise Sequel::Error,
                "Property '#{prop_name}' (type: #{notion_type}) is not filterable"
        end

        op = empty ? "is_empty" : "is_not_empty"

        {
          "property" => prop_name,
          filter_key => { op => true }
        }
      end

      # ----------------------------------------------------------
      # Value coercion
      # ----------------------------------------------------------

      def coerce_value(value, filter_key)
        case filter_key
        when "date"
          value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
        when "checkbox"
          !!value
        when "number"
          value.is_a?(Numeric) ? value : value.to_f
        else
          value.to_s
        end
      end

      # ----------------------------------------------------------
      # Negation (De Morgan)
      # ----------------------------------------------------------

      def negate(filter)
        if filter.key?("and")
          { "or" => filter["and"].map { |f| negate(f) } }
        elsif filter.key?("or")
          { "and" => filter["or"].map { |f| negate(f) } }
        else
          type_key = (filter.keys - ["property"]).first
          inner    = filter[type_key]
          negated  = inner.transform_keys do |k|
            case k
            when "is_empty"     then "is_not_empty"
            when "is_not_empty" then "is_empty"
            else
              if k.start_with?("does_not")
                k.sub("does_not_", "")
              else
                "does_not_#{k}"
              end
            end
          end
          { "property" => filter["property"], type_key => negated }
        end
      end
    end
  end
end
