# frozen_string_literal: true

module Sequel
    module Notion
        # One aggregate over one group, kept as a running value rather
        # than the group's rows: count, sum, avg, min or max of the
        # non-NULL values, as SQL defines them. count(*) is a count of a
        # value given once per row.
        class GroupAccumulator
            FUNCTIONS = %i[count sum avg min max].freeze

            def initialize(function)
                @function = function
                @count    = 0
                @value    = nil
            end

            def add(value)
                return if value.nil?

                numeric!(value)
                @count += 1
                @value = @value.nil? ? value : combined(value)
            rescue ArgumentError
                raise Error, "cannot compute #{@function} of #{value.inspect}"
            end

            def value
                case @function
                when :count then @count
                when :avg then @value&.fdiv(@count)
                else @value
                end
            end

            private

            def numeric!(value)
                return if value.is_a?(Numeric)
                return unless %i[sum avg].include?(@function)

                raise Error, "cannot compute #{@function} of #{value.inspect}"
            end

            def combined(value)
                case @function
                when :sum, :avg then @value + value
                when :min then [@value, value].min
                when :max then [@value, value].max
                else @value
                end
            end
        end
    end
end
