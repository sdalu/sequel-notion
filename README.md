# sequel-notion

A [Sequel](https://sequel.jeremyevans.net/) adapter for Notion. Each Notion
**data source** (the tables inside a Notion database, API version
`2026-03-11`) is a Sequel table: you read it with `where`, `order`,
`limit` and `select`, write it with `insert`, `update` and `delete`, and
can put a `Sequel::Model` on top of it.

Every Sequel call becomes one or more Notion API requests. Nothing is
translated to SQL. Clauses, selections and comparisons Notion cannot
express raise a `Sequel::Error` instead of being dropped.


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

| Option            | Meaning                                                         |
|-------------------|-----------------------------------------------------------------|
| `token`           | The integration token (required)                                |
| `auto_register`   | On the first lookup, register every data source the token sees  |
| `faraday_adapter` | Faraday adapter (default `Faraday.default_adapter`); the test suite passes `[:test, stubs]` |


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

DB.tables                      # => [:tasks, ...]
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
source that has one raises; rename the property in Notion. A date reads
back as its ISO 8601 start, or as a `Range` of the two strings when it has
an end, which a write takes back as is; a unique ID as Notion shows it,
`"TK-62"`; title and rich text as plain text; select and status as the
option name; multi-select, people and relation as an `Array` of names or
ids; files as `Sequel::Notion::File`s; a rollup as its value, a number,
a date, or an `Array` of the rolled-up values read the same way.

| Sequel                                  | Notion filter                              |
|-----------------------------------------|--------------------------------------------|
| `where(P: v)`, `exclude(P: v)`          | `equals`, `does_not_equal`                 |
| `where(P: nil)`                         | `is_empty` (`is_not_empty` when excluded), also for a formula or a rollup |
| `where(Done: true)`, `where(:Done)`     | checkbox `equals`, also for a checkbox formula |
| `where(P: [a, b])`                      | `or` of `equals`; a `nil` in the list is `is_empty` |
| `<`, `<=`, `>`, `>=`                    | number comparisons; `before`/`after`/`on_or_…` on dates |
| `Sequel.like(:P, "%x%")`, `"x%"`, `"%x"`, `"x"` | `contains`, `starts_with`, `ends_with`, `equals` |
| `Sequel.like(:P, "%")` (wildcards only) | `is_not_empty` (`is_empty` for `NOT LIKE`) |
| multi-select, people, relation `=`      | `contains`                                 |
| formula                                 | nested by the value's class: `string`, `number`, `checkbox`, `date` |
| unique id `=`, `<`, …                   | `unique_id` on its number, given as `62` or `"TK-62"` |
| rollup `=`, `<`, `IN`, …                | nested under `number` or `date`, for a rollup whose function gives one value (`sum`, `count`, `latest_date`, …) |
| `&`, `\|`, `~`                          | `and`, `or`, and the inverse operator      |

Negations follow SQL, where `!=` never matches `NULL`: Notion's
`does_not_equal` and `does_not_contain` match an empty property, so
`exclude(N: 1)`, `NOT LIKE` and `NOT IN` add `is_not_empty` beside them
(a checkbox is never empty and needs none). Notion nests `and`/`or` two
levels deep at most: an `and` inside an `and` is merged into it, a level
too many is distributed (`(a & b) | c` becomes `(a | c) & (b | c)`, up to
32 clauses), and a filter still deeper raises.

`order` maps to Notion sorts. Notion puts empty values last in both
directions, so `nulls: :first` raises and `nulls: :last` changes nothing.
Ordering by `:id` or `:in_trash` raises: they are the page's own columns,
not properties Notion can sort by.
`offset` is applied client side, so the rows it
skips are still fetched. `count` pages through the results. Requests are
paginated automatically. `paged_each` follows Notion's cursor, as
Sequel's cursor adapters do: it needs no order, sends one request per
`rows_per_fetch` rows (at most 100), and ignores `:strategy`.

`where(id: "…")` or `where(id: [...])` fetches those pages directly,
including pages in the trash (`:in_trash` says so). An id may be written
with or without dashes, in either case, and a repeated id gives one row. Several id conditions intersect. A missing page, or one from another data source, is no row.
An `id` condition cannot be combined with other conditions.

`select(:Name, Sequel.as(:Due, :due))` keeps only those keys, renamed by
the alias. Only plain, existing columns can be selected.


## Writing

```ruby
id = DB[:tasks].insert(Name: "Write the adapter", Status: "Todo",
                       Tags: %w[ruby notion], Due: Date.today)
DB[:tasks].where(Status: "Todo").update(Status: "Done")
DB[:tasks].where(id: id).delete          # moves the page to the trash
```

Values are encoded according to the property's Notion type, read from the
data source:

| Notion type                     | Ruby value                                   | `nil` clears to |
|---------------------------------|----------------------------------------------|-----------------|
| title, rich_text                | anything (`to_s`), split into runs of 2000 characters as Notion counts them (an emoji is two) | `[]` |
| number                          | a finite `Numeric` (sent as Integer or Float), or a decimal `String` (`"1e3"`, not `"0x1A"` or `"1_000"`), also in filters | `null` |
| select, status                  | the option name                              | `null`          |
| multi_select                    | an `Array` of names, or one name             | `[]`            |
| date                            | `Date`, `Time`, a `Range` of them, an ISO 8601 `String`, or `{start:, end:}` | `null` |
| checkbox                        | `true` / `false`                             | `false`         |
| url, email, phone_number        | `to_s`                                       | `null`          |
| relation                        | page id(s)                                   | `[]`            |
| people                          | user id(s)                                   | `[]`            |
| files                           | `Sequel::Notion::File`, a URL, or an `Array` of them; unnamed, a file is named after the URL's last path segment; a file of a type the adapter does not know reads back with its `raw` hash and is written back unchanged | `[]`    |

Notion's date ranges include their end, so an exclusive range
`d1...d2` ends on the day before `d2`. It must then end on a `Date`; an
exclusive `Time` range raises. A range needs a start: `d1..` leaves the
end open, and `..d2` raises, as does a `Hash` with no `:start`; `nil`
clears a date.

NaN and Infinity, which JSON cannot carry, raise `Sequel::Error` in a
write or a filter, and so does an external file URL that does not parse
(a space in it, for instance).

Writing a computed property (formula, rollup, created/edited time or by,
unique_id, button, verification) or an unknown property raises
`Sequel::Error`. `insert` ignores `:id`; `update` ignores `:id` and
turns `:in_trash` into trashing or restoring the page, so
`where(id: id).update(in_trash: false)` restores a trashed page. A
positional `insert(["a", 2])` fills the writable columns in schema order.

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
make the loss permanent. Notion cannot sort by page id, so a model adds
no primary key order: `Task.paged_each` streams in Notion's order, and
`Task.last` needs an explicit one, or raises Sequel's `No order
specified`. A unique ID property gives one in creation order:
`Task.order(:ID).last`. Sequel's `paged_operations` plugin pages
by primary key ranges, so it raises on a Notion model. Computed
properties are marked `generated` in the schema, for Sequel's
`skip_saving_columns` plugin. Date columns are not typecast, so a `Time`
or a `Range` reaches Notion as given.

Notion has no transactions: `DB.transaction` runs its block, swallows
`Sequel::Rollback` (re-raised with `rollback: :reraise`), and rolls nothing
back. `rollback: :always` raises, since every write would be kept.


## Schema

`DB.schema(:tasks)` lists `:id`, `:in_trash` and each property, with
`:db_type` set to its Notion type; computed properties are marked
`generated: true`. It is cached per data source. `DB.table_exists?`
answers by resolving the name and fetching the data source. Call
`DB.refresh_schema!(:tasks)` after changing the data source's properties
in Notion.


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

- No joins, grouping, `distinct`, unions, raw SQL (`with_sql`), or
  aggregates other than `count`. Each raises.
- Filters compare a property with a value, never with another property or
  an expression.
- `offset` and `count` fetch the pages they skip or count.
- `LIKE` patterns are limited to the shapes in the filter table above. A `_`
  wildcard or a `%` in the middle raises. Notion's own case rules apply to
  both `LIKE` and `ILIKE`. On a multi-select, people or relation property,
  Notion matches whole values only, so a pattern with any `%` raises.
- A rollup that keeps every value (`show_original`, `show_unique`) cannot
  be filtered: Notion's `any`/`every`/`none` have no SQL reading.
- A page lists at most 25 relations or people; a row's relation flagged
  `has_more`, or 25 people (Notion flags none), is completed from the
  page property endpoint, page by page, for the columns a
  query selects. Mentions inside a title or rich text are still cut at
  25, unflagged.
- Notion's rate limit is 3 requests per second on most plans, so a large
  `update` or `delete` is slow.
- Checked against the live API (2026-10-09): filters on title, url and
  email through the `rich_text` key and on created and edited times
  through the `date` key; page lookups by id with or without dashes;
  page creation with the `data_source_id` parent; writing, reading back
  and clearing every writable type; trashing and restoring; and a
  `Sequel::Model` create, update and destroy, and a `save` of a loaded
  record keeping a date range's end and its relations; `paged_each`
  following the cursor with a `page_size` below 100; negated filters
  excluding empty values, and filters merged or distributed to two
  levels; a relation of 26 pages read in full; a date range read back
  as a `Range` and written back; unique ID filters and sorts; rollups of
  a number, dates and titles read as values; filters and sorts on a sum
  rollup; `nil` filters on string and number formulas and a sum rollup;
  formula
  negations excluding empty results; and that search keeps
  listing a trashed data source, flagged `in_trash`.


## License

MIT — see `LICENSE.txt`.
