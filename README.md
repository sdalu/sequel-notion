# sequel-notion

A [Sequel](https://sequel.jeremyevans.net/) adapter for Notion. Each Notion
**data source** (the tables inside a Notion database, API version
`2026-03-11`) is a Sequel table: you read it with `where`, `order`,
`limit` and `select`, write it with `insert`, `update` and `delete`, and
can put a `Sequel::Model` on top of it.

Every Sequel call becomes one or more Notion API requests; nothing is
translated to SQL. What Notion can answer is sent to Notion. What it
cannot — joins, groups, aggregates, `distinct`, unions — is computed in
Ruby, only on a dataset that asks for it with `client_side`. Anything
else raises a `Sequel::Error` rather than be dropped.

- [Requirements](#requirements)
- [Installation](#installation)
- [Connecting](#connecting)
- [Naming tables](#naming-tables)
- [Reading](#reading)
- [Computed in Ruby](#computed-in-ruby)
- [Values](#values)
- [Writing](#writing)
- [Models](#models)
- [Schema](#schema)
- [Errors, retries and logging](#errors-retries-and-logging)
- [Known shortfalls](#known-shortfalls)
- [Checked against the live API](#checked-against-the-live-api)


## Requirements

- Ruby **>= 3.4**
- A Notion integration token, with the integration shared to the pages
  and databases it should see


## Installation

```sh
gem install sequel-notion
```

Or from a checkout:

```sh
bundle install
bundle exec rake test
```


## Connecting

```ruby
require "sequel"

DB = Sequel.connect(adapter: :notion, token: ENV["NOTION_TOKEN"])
```

| Option            | Meaning                                             |
| ----------------- | --------------------------------------------------- |
| `token`           | The integration token (required)                    |
| `auto_register`   | Discover every data source on the first lookup      |
| `faraday_adapter` | Faraday adapter (default `Faraday.default_adapter`) |

The test suite passes `faraday_adapter: [:test, stubs]` to answer for
Notion.


## Naming tables

A table name is resolved to a data source id in this order:

1. a name registered with `register_data_source` or
   `register_all_data_sources`;
2. a table name that is itself a data source id (32 hex digits, dashes
   optional, either case);
3. with `auto_register: true`, every data source the token can see,
   discovered once;
4. a search for a data source whose title normalises to the table
   name. The result is remembered; two matching data sources raise.

Titles normalise to lower snake case. Accents are dropped from Latin
letters only, and other scripts are kept as they are: `"My Tasks"` →
`:my_tasks`, `"Électricité"` → `:electricite`, `"タスク"` → `:タスク`. A
title with no letter or digit (`"🚀"`) is registered under its id.
A data source in the trash is never named by discovery, a search or
`register_all_data_sources`, though `data_sources` still lists it with
`in_trash: true`.

```ruby
DB.register_data_source(:tasks, "<data source id>")
DB.register_all_data_sources(database: "<database id>")
DB.register_all_data_sources { |title, id| "notion_#{title}" }   # by search

DB.tables                       # => [:tasks, ...]
DB.data_sources(query: "Bills") # => [{id:, name:, parent_database_id:, ...}]
```

A name already bound to a different data source raises an error rather than
being rebound, and `register_all_data_sources` then registers none of the
names it found. Discovery is more lenient: a name two data sources share
is left out of `tables` and raises when it is looked up, until
`register_data_source` picks one; the other names register as usual, and
discovery keeps a name already registered.


## Reading

```ruby
DB[:tasks].where(Status: "In Progress", Done: false)
          .order(Sequel.desc(:Due))
          .limit(25)
          .all
```

Each row has `:id` (the page id), `:in_trash`, and one key per property,
named as in Notion (`:"Due Date"` for a property with a space). A property
named `id` or `in_trash` would hide the page's own column, so a data
source that has one raises; rename the property in Notion. What each
type reads back as is under [Values](#values).

### Filters

| Sequel                         | Notion filter                          |
| ------------------------------ | -------------------------------------- |
| `where(P: v)`, `exclude(P: v)` | `equals`, `does_not_equal`             |
| `where(P: nil)`                | `is_empty`; excluded: `is_not_empty`   |
| `where(Done: true)`            | checkbox `equals`, or a formula's      |
| `where(:Done)`                 | the same                               |
| `where(P: [a, b])`             | `or` of `equals`; `nil` is empty       |
| `where(P: [])`                 | no page: no request is sent            |
| `exclude(P: [])`               | every page: no filter is sent          |
| `<`, `<=`, `>`, `>=`           | numbers; dates: `before`, `after`, …   |
| `Sequel.like(:P, "%x%")`       | `contains`                             |
| `"x%"`, `"%x"`, `"x"`          | `starts_with`, `ends_with`, `equals`   |
| `Sequel.like(:P, "%")`         | `is_not_empty`; `NOT LIKE`: `is_empty` |
| multi-select, people, relation | `=` as `contains`                      |
| formula                        | nested by the value's class            |
| rollup giving one value        | nested under `number` or `date`        |
| unique ID                      | its number: `62` or `"TK-62"`          |
| `&`, `\|`, `~`                 | `and`, `or`, and the inverse operator  |

A rollup filters when its function gives one value (`sum`, `count`,
`latest_date`, …). `nil` filters work on formulas and rollups too.

Negations follow SQL, where `!=` never matches `NULL`: Notion's
`does_not_equal` and `does_not_contain` match an empty property, so
`exclude(Status: "Done")`, `NOT LIKE` and `NOT IN` add `is_not_empty`
beside them, whatever the property's type (a checkbox or a unique ID is
never empty and needs none). Notion nests
`and`/`or` two levels deep at most: an `and` inside an `and` is merged
into it, a level too many is distributed (`(a & b) | c` becomes
`(a | c) & (b | c)`, up to 32 clauses), and a filter still deeper raises.

### Ordering

`order` maps to Notion sorts. Notion puts empty values last in both
directions, so `nulls: :first` raises and `nulls: :last` changes nothing.
Ordering by `:id` or `:in_trash` raises: they are the page's own columns,
not properties Notion can sort by. A checkbox sorts `false` first (checked
live), and so do rows computed in Ruby. Pages looked up by id are sorted
in Ruby, as a query's would be.

### Pages by id, and selection

`where(id: "…")` or `where(id: [...])` fetches those pages directly,
including pages in the trash (`:in_trash` says so). An id may be written
with or without dashes, in either case, and a repeated id gives one row.
Several id conditions intersect. A missing page, or one from another
data source, is no row. An `id` condition combined with any other
condition raises `Sequel::Error`.

`select(:Name, Sequel.as(:Due, :due))` keeps only those keys, renamed by
the alias. Only plain, existing columns can be selected.

### Paging

Requests are paginated automatically, 100 rows each. `offset` is
applied to the rows read, so the rows it skips are still fetched, and
`count` pages through the results; neither needs `client_side`.
`paged_each` follows Notion's cursor, as Sequel's cursor adapters do: it
needs no order, sends one request per `rows_per_fetch` rows (at most
100), and ignores `:strategy`.


## Computed in Ruby

Notion computes no aggregate, `distinct`, group, join or combination of
queries. The adapter works them out in Ruby over every row the query
returns, at 100 rows per request and about 3 requests a second, so it
does so only on a dataset that asks for it; otherwise such a query
raises before sending anything:

```ruby
DB[:tasks].sum(:Hours)                       # raises: needs client_side
DB[:tasks].client_side.sum(:Hours)           # reads every task
DB[:tasks].client_side(max_requests: 20)     # and at most 20 requests
          .join(:projects, id: :Project).all
Task.client_side.group_and_count(:Status).all
```

```text
query ──▸ needs Ruby? ── no ──▸ Notion: where → filter, order →
          (join, group,          sorts; offset and limit on the
          distinct, sum, …)      pages read
             │ yes
             ▾
          client_side? ── no ──▸ Sequel::Error, nothing sent
             │ yes
             ▾
          Notion: one query per table, with the where
             │  conditions that test it; max_requests caps
             │  the requests of all of them
             ▾
          Ruby: match, group, aggregate or combine the rows,
                then order, offset and limit
```

`max_requests` counts every request of one query that Notion answers
with a 200, both tables of a join and both sides of a union included; a
rate-limited attempt the adapter retries, or a request that fails (a
page gone), counts nothing. The query raises `Sequel::Error` before the
request past it. A query run on a row inside `each` is a query of its
own, with its own budget.

- **Aggregates.** `sum`, `avg`, `min`, `max` and `count(:col)` skip
  `nil`s and give `nil` over no value.
- **Distinct.** `distinct` drops repeated rows before `offset` and
  `limit`; `distinct(:P)` keeps the first row of each value, in the
  query's order.
- **Groups.** `group(:P)` with the columns it groups and `count`, `sum`,
  `avg`, `min` or `max` (`group_and_count`, `select_group`) keeps one
  running value per group; `order`, `offset` and `limit` then apply to
  the groups, empty values last. `having` filters them, on an aggregate
  written out (`having { count.function.* > 1 }`) or on an output's
  name, with SQL's rules for `nil`.
- **Combined queries.** `union` (with or without `all:`), `intersect` and
  `except` (without `all:`) combine the rows of two queries as SQL does:
  the result takes the first query's column names, the other's values
  matched by position, and queries selecting a different number of
  columns raise. `order`, `offset`, `limit` and a `select` of columns
  apply to the
  result, and a `where`, `group`, `having`, `distinct` or join added to
  it raises.
- **Joins.** `join` and `left_join` match rows on one equality, and a
  relation matches every page it lists, so a join follows it:

  ```ruby
  DB[:tasks].client_side.join(:projects, id: :Project)
            .where(Sequel[:projects][:Budget] > 1000)
            .select(Sequel[:tasks][:Name].as(:task),
                    Sequel[:projects][:Name].as(:project))
  ```

  Each `where` condition that tests one table runs in Notion, on that
  table's query. On a left join's joined table it still filters the
  joined rows, as SQL's `WHERE` does: a row whose partners all fail it
  is dropped, and a row with no partner is kept only if an empty page
  passes it (`where(Sequel[:projects][:Budget] => nil)`); that table is
  queried twice, with and without the condition. A column both tables
  have must be qualified. Without a
  `select`, a later table's column wins a shared name, as with SQL
  adapters.


## Values

How each Notion type reads back, and what a write takes for it:

| Notion type         | Reads as                | A write takes               |
| ------------------- | ----------------------- | --------------------------- |
| title, rich_text    | plain text              | anything (`to_s`)           |
| number              | Integer or Float        | `Numeric`, decimal `String` |
| select, status      | the option name         | the option name             |
| multi_select        | an `Array` of names     | an `Array` of names, or one |
| date                | ISO start, or a `Range` | `Date`, `Time`, `Range`, …  |
| checkbox            | `true` / `false`        | `true` / `false`            |
| url, email, phone   | a `String`              | `to_s`                      |
| relation            | an `Array` of page ids  | page id(s)                  |
| people              | an `Array` of user ids  | user id(s)                  |
| files               | `Sequel::Notion::File`s | `File`, URL, or an `Array`  |
| formula             | its result              | read-only                   |
| rollup              | its value               | read-only                   |
| unique_id           | as shown, `"TK-62"`     | read-only                   |
| created/edited time | an ISO 8601 `String`    | read-only                   |
| created/edited by   | Notion's user object    | read-only                   |

`nil` clears a property: to `[]` for text and lists, `false` for a
checkbox, `null` otherwise.

- **Text** is written in runs of 2000 characters as Notion counts them
  (an emoji is two).
- **Numbers** given as a `String` must be decimal (`"1e3"`, not `"0x1A"`
  or `"1_000"`), in writes and filters alike; a number other than
  Integer or Float is sent as a Float.
- **Dates** read back as the ISO 8601 start, or as a `Range` of the two
  strings when the date has an end, which a write takes back as is. A
  write also takes an ISO 8601 `String` or `{start:, end:}`. Notion's
  date ranges include their end, so an exclusive range `d1...d2` ends on
  the day before `d2`; it must then end on a `Date`, and an exclusive
  `Time` range raises. A range needs a start: `d1..` leaves the end
  open, and `..d2` raises, as does a `Hash` with no `:start`. Notion
  keeps a time to the minute: `10:20:30.123` reads back as `10:20:00`
  (checked live). A date filter takes a `Date`, `Time`, `DateTime` or
  ISO 8601 string, and raises on anything else.
- **Relations and people** read back in full: a page lists at most 25,
  and the rest is fetched from Notion for the columns a query selects.
- **Files**: an unnamed file is named after the URL's last path segment,
  decoded (`a%20b.pdf` names it `a b.pdf`);
  a file of a type the adapter does not know reads back with its `raw`
  hash and is written back unchanged.
- **Rollups** read as their value: a number, a date, or an `Array` of
  the rolled-up values, each read as its own type.

NaN and Infinity, which JSON cannot carry, raise `Sequel::Error` in a
write or a filter, and so does an external file URL that does not parse
(a space in it, for instance).


## Writing

```ruby
id = DB[:tasks].insert(Name: "Write the adapter", Status: "Todo",
                       Tags: %w[ruby notion], Due: Date.today)
DB[:tasks].where(Status: "Todo").update(Status: "Done")
DB[:tasks].where(id: id).delete          # moves the page to the trash
```

Values are encoded according to the property's Notion type, read from
the data source (see [Values](#values)). Writing a computed property
(formula, rollup, created/edited time or by, unique ID, button,
verification) or an unknown property raises `Sequel::Error`. `insert`
ignores `:id`; `update` ignores `:id` and turns `:in_trash` into
trashing or restoring the page, so `where(id: id).update(in_trash: false)`
restores a trashed page. A positional `insert(["a", 2])` fills the
writable columns in schema order.

`update` and `delete` first collect the matching page ids, then send one
request per page.


## Models

```ruby
class Task < Sequel::Model(DB[:tasks])
end

task = Task.create(Name: "Ship it", Status: "Todo")
task.update(Status: "Done")
Task[task.id].delete
```

The primary key is `:id`. A `save` of a loaded record sends only the
columns that changed, as `update` and `save_changes` do: a row reads
back rich text as plain text, and writing the whole row back would
make the loss permanent. Computed properties are marked `generated` in
the schema, for Sequel's `skip_saving_columns` plugin. Date columns are
not typecast, so a `Time` or a `Range` reaches Notion as given.

Notion cannot sort by page id, so a model adds no primary key order:
`Task.paged_each` streams in Notion's order, and `Task.last` needs an
explicit one, or raises Sequel's `No order specified`. A unique ID
property gives one in creation order, `Task.order(:ID).last`. A
created-time property does too, `Task.order(:Created).last`, but only to
the minute: Notion stores created and edited times without seconds, so
pages created in the same minute tie. Sequel's
`paged_operations` plugin pages by primary key ranges, so it raises on a
Notion model. `Task.client_side` opens what is
[computed in Ruby](#computed-in-ruby) to a model.

Notion has no transactions: `DB.transaction` runs its block, swallows
`Sequel::Rollback` (re-raised with `rollback: :reraise`), and rolls nothing
back. `rollback: :always` raises, since every write would be kept.


## Schema

`DB.schema(:tasks)` lists `:id`, `:in_trash` and each property, with
`:db_type` set to its Notion type; computed properties are marked
`generated: true`. It is cached per data source. `DB.table_exists?`
answers by resolving the name and fetching the data source. Call
`DB.refresh_schema!(:tasks)` after changing the data source's properties
in Notion; every name of that data source (an alias, its id) sees the
change.


## Errors, retries and logging

- A failed request, or a response that is not valid JSON, raises
  `Sequel::DatabaseError`, with Notion's error code and message in the
  text. A 404 raises its subclass `Sequel::Notion::NotFoundError`
  (`where(id:)` turns it into no row).
- Responses 429, 502, 503 and 504 are retried up to four times, honouring
  `Retry-After`. Page creation is retried only after a 429, so a timeout
  cannot create a page twice.
- Requests go to the database's loggers (`DB.loggers << Logger.new($stdout)`)
  as `POST data_sources/…/query` with their body.


## Known shortfalls

- No raw SQL (`with_sql`, `run`, `truncate`, schema changes): there is
  no SQL to run it, and each raises `Sequel::Error`. No locks
  (`for_update`): Notion has none.
- Joins are inner or left, on one equality; right, full and cross joins,
  and a `where` condition testing two tables, raise.
- What is [computed in Ruby](#computed-in-ruby) reads every
  row its queries return, and so do `offset` and `count`.
- Filters compare a property with a value, never with another property or
  an expression.
- `LIKE` patterns are limited to the shapes in the filter table. A `_`
  wildcard or a `%` in the middle raises. Notion's own case rules apply to
  both `LIKE` and `ILIKE`. On a multi-select, people or relation property,
  Notion matches whole values only, so a pattern with any `%` raises.
- A rollup that keeps every value (`show_original`, `show_unique`) cannot
  be filtered: Notion's `any`/`every`/`none` have no SQL reading.
- Mentions inside a title or rich text are cut at 25 by Notion, unflagged,
  and are not completed.
- Notion's rate limit is 3 requests per second on most plans, so a large
  `update` or `delete` is slow. The retry on a 429 is tested against
  stubs only: bursts of 30 and 90 parallel queries drew no 429 from
  Notion (2026-10-09).


## Checked against the live API

The suite stubs Notion, so it proves the payloads match what the adapter
believes Notion accepts. These were also checked against
`api.notion.com` (2026-10-09):

- **Filters:** title, url and email through the `rich_text` key; created
  and edited times through the `date` key; negations excluding empty
  values, formula negations excluding empty results, a rollup negation
  guarded against an empty average, `NOT IN` on dates and created
  times, and filters merged
  or distributed to two levels; unique ID filters and sorts; filters and
  sorts on a sum rollup and on a `latest_date` rollup; `nil` filters on
  string and number formulas and on both rollups.
- **Dates:** a time written to a date property kept to the minute.
- **Checkboxes:** sorted `false` first, `true` first descending.
- **Files:** a Notion-hosted file read from a page and written back
  unchanged, signed URL included, kept by Notion.
- **Pages:** lookups by id with or without dashes; creation with the
  `data_source_id` parent; writing, reading back and clearing every
  writable type; trashing and restoring; a relation of 26 pages read in
  full; a date range read back as a `Range` and written back; rollups of
  a number, dates and titles read as values.
- **Models:** create, update and destroy; a `save` of a loaded record
  keeping a date range's end and its relations; `order` on a created-time
  property, whose values Notion stores to the minute.
- **Reading:** `paged_each` following the cursor with a `page_size` below
  100.
- **Computed in Ruby:** refused without `client_side` and no request
  sent; aggregates, `distinct`, `DISTINCT ON`, `group`, `having`,
  `union`, `intersect` and `except` over rows with and without values,
  and a `select` on their result;
  inner and left joins through a relation, with a `where` per side, a
  sum and a group over them; a left join's `where` on its joined table,
  equal to a value and empty; `max_requests` stopping a join.
- **Discovery:** search keeps listing a trashed data source, flagged
  `in_trash`.


## License

MIT — see `LICENSE.txt`.
