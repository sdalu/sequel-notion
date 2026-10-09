# frozen_string_literal: true

module Sequel
    module Notion
        # Tokenizes a SQL LIKE pattern into literal/wildcard pieces, mixed
        # into FilterCompiler. All private. Unescapes \% \_ \\ as literal
        # characters; unescaped % and _ become :wild / :underscore markers.
        module FilterLikeTokenizer
            ESCAPABLE_LIKE_CHARS = %w[% _ \\].freeze

            private

            def tokenize_like_pattern(pattern)
                tokens = []
                chars = pattern.chars
                i = 0
                while i < chars.length
                    token, consumed = next_like_token(chars, i)
                    tokens << token
                    i += consumed
                end
                tokens
            end

            def next_like_token(chars, i)
                c = chars[i]
                return [[:lit, chars[i + 1]], 2] if escaped_like_char?(chars, i)

                case c
                when "%" then [[:wild], 1]
                when "_" then [[:underscore], 1]
                else [[:lit, c], 1]
                end
            end

            def escaped_like_char?(chars, i)
                chars[i] == "\\" && i + 1 < chars.length &&
                    ESCAPABLE_LIKE_CHARS.include?(chars[i + 1])
            end
        end
    end
end
