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
        union_renamed: lambda {
            it[:tasks].select(:Name, :N)
                      .union(it[:tasks].select(Sequel[:Name].as(:x),
                                               Sequel[:N].as(:y))).all
        },
        intersect_renamed: lambda {
            it[:tasks].where(Sequel[:N] > 0).select(:Name, :N)
                      .intersect(it[:tasks].select(Sequel[:Name].as(:x),
                                                   Sequel[:N].as(:y))).all
        },
        except_swapped: lambda {
            it[:tasks].select(:Name, :Kind)
                      .except(it[:tasks].select(:Kind, :Name)).all
        },
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
        # Dates: Notion's date operators and before-or-after
        date_equal: -> { due(it, Sequel[:Due] => D2) },
        date_not_equal: -> { due(it, Sequel.~(Due: D2)) },
        date_compare: lambda { |tables|
            [Sequel[:Due] > D1, Sequel[:Due] >= D2, Sequel[:Due] < D3,
             Sequel[:Due] <= D2].map { due(tables, it) }
        },
        date_in: -> { due(it, Due: [D1, D3]) },
        date_not_in: -> { due(it, Sequel.~(Due: [D1, D3])) },
        date_nil: -> { [due(it, Due: nil), due(it, Sequel.~(Due: nil))] },
        date_range: -> { due(it, Due: D1..D2) },
        date_min_max: lambda {
            [it[:tasks].min(:Due), it[:tasks].max(:Due),
             it[:tasks].count(:Due)]
        },
        date_group: -> { it[:tasks].group_and_count(:Due).all },
        date_distinct: -> { it[:tasks].select(:Due).distinct.all },
        date_order: lambda {
            it[:tasks].select(:Due, :Name)
                      .order(Sequel.desc(:Due, nulls: :last), :Name)
                      .limit(3).all
        },
        date_join: lambda {
            joined(it, :left_join).where(Sequel[:tasks][:Due] >= D2).all
        },
        # Selects: equality, lists, groups
        kind_equal: -> { kind(it, Kind: "x") },
        kind_not_equal: -> { kind(it, Sequel.~(Kind: "x")) },
        kind_in: -> { kind(it, Kind: %w[x z]) },
        kind_not_in: -> { kind(it, Sequel.~(Kind: %w[x z])) },
        kind_nil: -> { [kind(it, Kind: nil), kind(it, Sequel.~(Kind: nil))] },
        kind_group: lambda {
            it[:tasks].group(:Kind).select(:Kind) do
                [count.function.*.as(:c), sum(:N).as(:s), max(:Due).as(:d)]
            end.all
        },
        kind_having: lambda {
            it[:tasks].group(:Kind).select(:Kind) { count.function.*.as(:c) }
                      .having { count.function.* >= 2 }.all
        },
        kind_distinct: -> { it[:tasks].select(:Kind).distinct.all },
        kind_min: -> { [it[:tasks].min(:Kind), it[:tasks].max(:Kind)] },
        kind_union: lambda {
            it[:tasks].where(Kind: "x").select(:Kind, :Due)
                      .union(it[:tasks].where(Sequel[:Due] > D1)
                                       .select(:Kind, :Due)).all
        },
        join_order_limit: lambda {
            joined(it, :join)
                .order(:task, :project, Sequel.asc(:n, nulls: :last),
                       Sequel.asc(:budget, nulls: :last),
                       Sequel.asc(:due, nulls: :last))
                .limit(2).offset(1).all
        }
    }.freeze

    ORDERED = %i[distinct_limit group_order_limit union_order
                 join_order_limit date_order].freeze

    def self.ns(tables, above)
        tables[:tasks].where(Sequel[:N] > above).select(:N)
    end

    D1, D2, D3 = SqlOracle::DATES.compact.uniq

    def self.due(tables, cond)
        tables[:tasks].where(cond).select(:Name, :Due).all
    end

    def self.kind(tables, cond)
        tables[:tasks].where(cond).select(:Name, :Kind).all
    end

    def self.joined(tables, how)
        tables[:tasks].public_send(how, :projects, id: :Proj)
                      .select(Sequel[:tasks][:Name].as(:task),
                              Sequel[:tasks][:N].as(:n),
                              Sequel[:tasks][:Due].as(:due),
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
