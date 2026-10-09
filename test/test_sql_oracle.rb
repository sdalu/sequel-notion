# frozen_string_literal: true

require "test_helper"
require "sql_oracle"

# What the adapter computes in Ruby (aggregates, groups, HAVING,
# DISTINCT, compounds, joins) checked against SQLite: the same rows go to
# a stubbed Notion, which applies filters and sorts as Notion does, and
# to an in-memory SQLite table, and the same Sequel query must give the
# same rows on both. Each seed draws a new data set, empty values,
# repeats and unmatched relations included.
class TestSqlOracle < Minitest::Test
    include SqlOracle

    SEEDS = 25

    # name => query, given a table factory; an order-free result is
    # compared as a multiset
    QUERIES = {
        count: -> { it[:tasks].count },
        count_col: -> { it[:tasks].count(:N) },
        sum: -> { it[:tasks].sum(:N) },
        avg: -> { it[:tasks].avg(:N) },
        min_max: -> { [it[:tasks].min(:N), it[:tasks].max(:N)] },
        min_name: -> { it[:tasks].min(:Name) },
        filtered_sum: -> { it[:tasks].where(Sequel[:N] > 0).sum(:N) },
        excluded_count: -> { it[:tasks].exclude(N: 1).count },
        nil_count: -> { it[:tasks].where(N: nil).count },
        distinct: -> { it[:tasks].select(:Name).distinct.all },
        distinct_n: -> { it[:tasks].select(:N).distinct.all },
        distinct_limit: lambda {
            it[:tasks].select(:N).distinct
                      .order(Sequel.asc(:N, nulls: :last)).limit(2).all
        },
        group_count: -> { it[:tasks].group_and_count(:Name).all },
        group_nil_key: -> { it[:tasks].group_and_count(:N).all },
        group_aggs: lambda {
            it[:tasks].group(:Name).select(:Name) do
                [sum(:N).as(:s), avg(:N).as(:a), min(:N).as(:lo),
                 max(:N).as(:hi), count(:N).as(:c)]
            end.all
        },
        group_order_limit: lambda {
            it[:tasks].group_and_count(:Name).order(Sequel.desc(:count), :Name)
                      .limit(2).offset(1).all
        },
        having_count: lambda {
            it[:tasks].group(:Name).select(:Name) { count.function.*.as(:c) }
                      .having { count.function.* > 1 }.all
        },
        having_sum: lambda {
            it[:tasks].group(:Name).select(:Name) { sum(:N).as(:s) }
                      .having { sum(:N) >= 2 }.all
        },
        having_nil: lambda {
            it[:tasks].group(:N).select(:N) { count.function.*.as(:c) }
                      .having(N: nil).all
        },
        union: -> { ns(it, 0).union(ns(it, 2)).all },
        union_all: -> { ns(it, 0).union(ns(it, 2), all: true).all },
        intersect: -> { ns(it, 0).intersect(ns(it, 2)).all },
        except: -> { ns(it, 0).except(ns(it, 2)).all },
        union_order: lambda {
            ns(it, 0).union(ns(it, 2), all: true).order(Sequel.desc(:N))
                     .limit(3).offset(1).all
        },
        union_count: -> { ns(it, 0).union(ns(it, 2)).count },
        inner_join: -> { joined(it, :join).all },
        left_join: -> { joined(it, :left_join).all },
        left_join_where_left: lambda {
            joined(it, :left_join).where(Sequel[:tasks][:N] => 2).all
        },
        left_join_where_right: lambda {
            joined(it, :left_join).where(Sequel[:projects][:Budget] => 10).all
        },
        left_join_where_right_nil: lambda {
            joined(it, :left_join).where(Sequel[:projects][:Budget] => nil).all
        },
        left_join_right_gt: lambda {
            joined(it, :left_join).where(Sequel[:projects][:Budget] > 10).all
        },
        join_sum: lambda {
            it[:tasks].join(:projects, id: :Proj)
                      .sum(Sequel[:projects][:Budget])
        },
        join_group: lambda {
            it[:tasks].left_join(:projects, id: :Proj)
                      .group(Sequel[:projects][:Name])
                      .select(Sequel[:projects][:Name]) { count.function.*.as(:c) }
                      .all
        },
        join_order_limit: lambda {
            joined(it, :join)
                .order(:task, :project, Sequel.asc(:n, nulls: :last),
                       Sequel.asc(:budget, nulls: :last))
                .limit(2).offset(1).all
        }
    }.freeze

    ORDERED = %i[distinct_limit group_order_limit union_order
                 join_order_limit].freeze

    def self.ns(tables, above)
        tables[:tasks].where(Sequel[:N] > above).select(:N)
    end

    def self.joined(tables, how)
        tables[:tasks].public_send(how, :projects, id: :Proj)
                      .select(Sequel[:tasks][:Name].as(:task),
                              Sequel[:tasks][:N].as(:n),
                              Sequel[:projects][:Name].as(:project),
                              Sequel[:projects][:Budget].as(:budget))
    end

    QUERIES.each_key do |name|
        define_method(:"test_#{name}") do
            SEEDS.times { |seed| check(name, seed) }
        end
    end

    def check(name, seed)
        data     = dataset(Random.new(seed))
        expected = evaluate(QUERIES[name], sqlite(data))
        actual   = evaluate(QUERIES[name], notion(data))
        unless ORDERED.include?(name)
            expected = sorted(expected)
            actual   = sorted(actual)
        end
        assert_equal expected, actual, "#{name}, seed #{seed}: #{data}"
    end

    def evaluate(query, tables)
        normal(self.class.instance_exec(tables, &query))
    end

end
