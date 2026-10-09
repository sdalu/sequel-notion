# frozen_string_literal: true

require "sequel/notion/filter_tables"

module Sequel
    module Notion
        # LIKE / ILIKE / NOT LIKE / NOT ILIKE compilation (rule L), mixed
        # into FilterCompiler. All private.
        #
        # Notion does not distinguish case-sensitive from case-insensitive
        # text matching, so LIKE and ILIKE (and their NOT variants) are
        # treated identically here.
        module FilterLike
            # Carries the bits a LIKE-pattern error message needs, so the
            # tokenizing/classifying helpers below stay under the parameter
            # count limit.
            LikeContext = Struct.new(:name, :sequel_op, :pattern)

            private

            def compile_like(expr)
                left, pattern = expr.args
                name = FilterCompiler.property_name(left)
                validate_like_pattern!(pattern, name, expr.op)

                type = lookup_type!(name)
                key  = filter_key_for!(name, type)

                op, value = translate_like_pattern(pattern, name, expr.op)
                op = negate_like_operator(op, name) if negated_like?(expr.op)
                op = equal_to_contains(op) if contains_type?(key)
                ensure_supported!(name, key, op)

                { "property" => name, key => { op => value } }
            end

            def validate_like_pattern!(pattern, name, sequel_op)
                return if pattern.is_a?(String)

                raise Sequel::Error,
                      "Unsupported #{sequel_op} pattern for property " \
                      "'#{name}': #{pattern.inspect}"
            end

            def negated_like?(sequel_op)
                [:"NOT LIKE", :"NOT ILIKE"].include?(sequel_op)
            end

            def negate_like_operator(op, name)
                case op
                when "equals" then "does_not_equal"
                when "contains" then "does_not_contain"
                when "starts_with", "ends_with"
                    raise Sequel::Error,
                          "Notion has no negated #{op} operator " \
                          "(property '#{name}')"
                else op
                end
            end

            # Unescapes \% \_ \\ as literals, then classifies the remaining
            # (unescaped) wildcards into a Notion text operator.
            def translate_like_pattern(pattern, name, sequel_op)
                ctx = LikeContext.new(name, sequel_op, pattern)
                tokens = tokenize_like_pattern(pattern)
                reject_underscore_wildcard!(tokens, ctx)

                literal = like_literal(tokens)
                wild_idxs = like_wildcard_indexes(tokens)

                classify_like_wildcards(wild_idxs, tokens.length - 1,
                                        literal, ctx)
            end

            def reject_underscore_wildcard!(tokens, ctx)
                return unless tokens.any? { |t| t[0] == :underscore }

                raise Sequel::Error,
                      "Unsupported #{ctx.sequel_op} pattern for property " \
                      "'#{ctx.name}' (unescaped '_' is not supported): " \
                      "#{ctx.pattern.inspect}"
            end

            def like_literal(tokens)
                tokens.select { it[0] == :lit }.map { it[1] }.join
            end

            def like_wildcard_indexes(tokens)
                tokens.each_index.select { |idx| tokens[idx][0] == :wild }
            end

            def classify_like_wildcards(wild_idxs, last_idx, literal, ctx)
                case wild_idxs
                when [] then ["equals", literal]
                when [0] then classify_leading_wildcard(last_idx, literal, ctx)
                when [last_idx] then ["starts_with", literal]
                when [0, last_idx] then ["contains", literal]
                else
                    raise unsupported_wildcard_error(ctx)
                end
            end

            def classify_leading_wildcard(last_idx, literal, ctx)
                # pattern was just "%"
                raise unsupported_wildcard_error(ctx) if last_idx.zero?

                ["ends_with", literal]
            end

            def unsupported_wildcard_error(ctx)
                Sequel::Error.new(
                    "Unsupported #{ctx.sequel_op} pattern for property " \
                    "'#{ctx.name}' (unsupported wildcard placement): " \
                    "#{ctx.pattern.inspect}"
                )
            end
        end
    end
end
