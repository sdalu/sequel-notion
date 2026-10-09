# frozen_string_literal: true

require "test_helper"
require "sql_oracle"

# Sequel's own dataset methods (first, last, get, map, as_hash,
# where_all, paged_each, reverse, invert, update, delete, …) on the
# adapter and on SQLite, over the same rows: each gives the same value,
# or raises the same class of error. An order leaves empty values last,
# as Notion does.
class TestSequelApiOracle < Minitest::Test
    include SqlOracle

    SEEDS = 25
    C     = %i[Name N].freeze
    ORD   = [:Name, Sequel.asc(:N, nulls: :last)].freeze
    ID0   = "cccccccc-0000-0000-0000-000000000000"

    PROBES = {
        all_ordered: -> { it.select(*C).order(*ORD).all },
        brackets: -> { it.select(*C).order(*ORD)[Name: "a"] },
        as_hash: -> { it.as_hash(:id, :N) },
        as_set: -> { it.as_set(:N) },
        select_hash: -> { it.select_hash(:id, :Name) },
        select_hash_groups: lambda {
            it.select_hash_groups(:Name, :id).transform_values(&:sort)
        },
        select_map: -> { it.select_map(:N).sort_by(&:inspect) },
        select_map_multi: -> { it.select_map(C).sort_by(&:inspect) },
        select_order_map: -> { it.select_order_map(ORD.last) },
        select_order_map_desc: lambda {
            it.select_order_map(Sequel.desc(:N, nulls: :last))
        },
        select_set: -> { it.select_set(:Name) },
        single_record: -> { it.where(id: ID0).select(*C).single_record },
        single_value: -> { it.where(id: ID0).select(:Name).single_value },
        where_single_value: lambda {
            it.select(:Name).where_single_value(id: ID0)
        },
        get: -> { it.order(*ORD).get(:Name) },
        get_multi: -> { it.order(*ORD).get(C) },
        first_n: -> { it.select(*C).order(*ORD).first(3) },
        first_cond: -> { it.select(*C).order(*ORD).first(Name: "b") },
        first_bang: -> { it.where(Name: "zz").first! },
        last: -> { it.exclude(N: nil).select(*C).order(*C).last },
        last_n: -> { it.exclude(N: nil).select(*C).order(*C).last(2) },
        map: -> { it.order(*ORD).map(:N) },
        to_hash_groups: lambda {
            it.to_hash_groups(:Name, :id).transform_values(&:sort)
        },
        where_all: -> { it.select(*C).order(*ORD).where_all(N: 2) },
        where_each: lambda {
            rows = []
            it.select(*C).order(*ORD).where_each(N: 2) { rows << it }
            rows
        },
        empty: -> { [it.where(Name: "zz").empty?, it.empty?] },
        count_in: -> { it.where(Name: %w[a b]).count },
        limit_offset: -> { it.select(*C).order(*ORD).limit(3, 2).all },
        offset: -> { it.select(*C).order(*ORD).offset(2).all },
        paged_each: lambda {
            rows = []
            it.select(*C).order(*ORD).paged_each(rows_per_fetch: 2) do
                rows << it
            end
            rows
        },
        reverse: lambda {
            it.select(*C).order(:Name, Sequel.asc(:N, nulls: :first))
              .reverse.all
        },
        exclude_or: lambda {
            it.select(*C).exclude(Sequel.|({ Name: "a" }, { N: 2 }))
              .order(*ORD).all
        },
        invert: -> { it.select(*C).where(Name: "a").invert.order(*ORD).all },
        or: -> { it.select(*C).where(Name: "a").or(N: 3).order(*ORD).all },
        select_append: lambda {
            it.select(:Name).select_append(:N).order(*ORD).all
        },
        unordered: -> { it.order(:N).unordered.select_map(:Name).sort },
        ranges: lambda {
            [it.where(N: 0..2), it.where(N: 0...2), it.exclude(N: 0..2)]
                .map { it.select(*C).order(*ORD).all }
        },
        like: lambda {
            it.select(*C).where(Sequel.like(:Name, "a%")).order(*ORD).all
        },
        distinct_count: -> { it.select(:Name).distinct.count },
        group_hash: -> { it.group_and_count(:Name).to_hash(:Name, :count) },
        avg_empty: -> { it.where(Name: "zz").avg(:N) },
        update: -> { [it.where(Name: "a").update(N: 9), it.update(N: 8)] },
        delete: -> { it.where(N: 2).delete }
    }.freeze

    PROBES.each_key do |name|
        define_method(:"test_#{name}") do
            SEEDS.times { |seed| probe(name, seed) }
        end
    end

    def probe(name, seed)
        data     = dataset(Random.new(seed))
        expected = outcome { normal(PROBES[name].call(sqlite(data)[:tasks])) }
        actual   = outcome { normal(PROBES[name].call(notion(data)[:tasks])) }
        assert_equal expected, actual, "#{name}, seed #{seed}: #{data[:tasks]}"
    end

    def outcome
        yield
    rescue StandardError => e
        e.class
    end
end
