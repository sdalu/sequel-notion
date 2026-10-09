# Changelog

## 0.2.0 — unreleased

### Added

- Reads every data source property type (formulas, rollups and the
  Notion unique ID included) and writes every writable one (title,
  status, select, relation, people, dates and date ranges, files);
  `nil` clears a property.
- Filters: `IS TRUE/FALSE`, `IN`, `LIKE` patterns, formula and rollup
  properties, date `!=`, `Sequel[:col]` and qualified columns, bare
  checkbox and formula columns, the Notion unique ID (`where(ID:
  "TK-62")`, `ID > 3`, `order(:ID)`, checked live).
- Filters nested deeper than Notion's two levels are merged or
  distributed into clauses, so `where(a).exclude(b: 1, c: 2)` and
  `where(a).where((b & c) | d)` work; what cannot fit raises instead of
  a 400.
- `where(id: …)` fetches pages directly; `Sequel::Model` works through
  Sequel's cached loaders and explicit primary keys; computed
  properties are `generated` for `skip_saving_columns`.
- 429 and 5xx responses are retried, honouring `Retry-After`; failures
  raise `Sequel::DatabaseError`; requests are logged.
- Trashed pages are reachable by id and can be restored; discovery, the
  search fallback and `register_all_data_sources` skip data sources in
  the trash, which Notion's search still lists.
- `table_exists?`, the pagination extension and `Sequel::Rollback`
  work. `paged_each` streams through Notion's cursor, needing no order
  and one request per page, instead of OFFSET pages that re-read every
  page before them.
- A relation Notion lists only 25 of (flagged `has_more`), or 25
  people, is read in full from the page property endpoint, for the
  columns a query returns (checked live with 26 relations).
- A rollup reads back as its value (a number, a date, or an `Array` of
  the rolled-up values) instead of a raw hash (checked live); a rollup
  whose function gives one value filters and sorts like one: `where(Sum:
  7)`, `Sum > 1`, `exclude`, `IN` (checked live for a sum and a
  `latest_date`). `IN` on a formula works too, and a formula date `!=`
  is `before or after` instead of raising. `where(F: nil)` on a formula
  or a rollup is `is_empty`, since Notion checks a formula's emptiness
  whatever its result type (checked live on string and number formulas);
  formula negations need no guard, since Notion already excludes an
  empty formula result (checked live).
- `sum`, `avg`, `min`, `max`, `count(:col)`, `distinct` and
  `distinct(:col)` (`DISTINCT ON`) work, computed in Ruby over the rows
  the query returns, with SQL's rules for `nil` and for `distinct`
  before `limit` (checked live).
- `group`, `group_and_count` and `select_group` work with `count`,
  `sum`, `avg`, `min` and `max`, computed in Ruby with one running value
  per group; `order`, `offset` and `limit` apply to the groups; `having`
  filters the groups, with SQL's three-valued logic (checked live).
- `union` (and `all:`), `intersect` and `except` work, computed in Ruby
  (checked live).
- `join` and `left_join` on one equality, matched in Ruby: a relation
  matches the pages it lists, each `where` condition runs in Notion on
  the one table it tests, and aggregates and groups keep a qualified
  column's table (checked live through a relation).

### Changed

- Ruby 3.4 is required.
- Files live under `lib/sequel/notion/`, as RubyGems' naming guide asks
  of a dashed gem name, and `require "sequel/notion"` (or Bundler's
  auto-require) loads the adapter.
- Negations follow SQL: `exclude(N: 1)`, `NOT LIKE` and `NOT IN` no
  longer match pages where the property is empty, as Notion's
  `does_not_equal` and `does_not_contain` did, and as the date `!=`
  already did not (checked live).
- A model's `save` of a loaded record sends only the changed columns,
  instead of every column, which used to write back what a row reads
  (a date's start only, the first 25 relations or people, rich text as
  plain text), dropping a range's end, the other relations and the
  formatting.
- `Task.last` needs an explicit order (a model adds no primary key
  order, so it raises Sequel's `No order specified` instead of "Notion
  cannot sort by id"); `order(:id)` and `order(:in_trash)` raise
  `Sequel::Error` instead of sending a sort Notion rejects with a 400.
- Operations Notion does not compute itself (joins, groups, aggregates,
  `distinct`, unions and the like) are computed in Ruby, only on a
  dataset that opts in with `client_side`, which `max_requests:` can
  cap; without it they raise before any request (checked live).

### Fixed

- `offset`, `count`, `empty?`, `get` and `select_map`.
- Table names keep non-Latin letters (`"タスク"` → `:タスク`) instead of
  normalising them all to the same empty name, which made a name lookup
  pick another data source and broke `register_all_data_sources`. A
  title with no letter or digit is named by its id, and a search that
  matches two data sources raises.
- An exclusive date `Range` ends on the day before; an exclusive `Time`
  range raises; a beginless `Range`, or a date `Hash` with no `:start`,
  raises `Sequel::Error` naming the property, instead of Notion's 400
  on a null start (checked live for the `Hash` case).
- A property named `id` or `in_trash` raises instead of overwriting the
  page's own column.
- `where(id: [a, a])` gives one row, and an id matches itself written
  with or without dashes.
- With `auto_register`, a lookup or `tables` made while another thread
  is discovering runs its own discovery and gets a complete answer,
  instead of reading a half-filled registry. Two data sources sharing a
  name no longer break every lookup: only that name raises, until
  `register_data_source` picks one. `register_data_source` keeps the id
  as a String, so registering the same id as a Symbol and as a
  String no longer raises, and discovery never overwrites it.
- Text is split into runs of 2000 UTF-16 units, the length Notion
  checks, so a long text with emoji is no longer rejected.
- NaN and Infinity, in a write or a filter, a numeric string that
  overflows to Infinity (`"1e400"`), and an external file URL that does
  not parse raise `Sequel::Error` instead of a JSON or URI error; a
  write names the property. A file URL with no path is named by the URL
  rather than `"/"` or `""`. A number given as a String must be
  decimal, in writes and filters: `"0x1A"` and `"1_000"` raise instead
  of becoming 26 and 1000.
- `where(F: true)` and `exclude(F: false)` on a checkbox formula filter
  through the formula's `checkbox` key instead of raising; a bare
  formula column, `where(:F)` or `exclude(:F)`, filters on its checkbox
  result instead of raising.
- `LIKE` with a wildcard on a multi-select, people or relation property
  raises: Notion's `contains` there matches a whole value, so `"%ruby%"`
  silently matched only the option `ruby`. `LIKE '%'` (wildcards only)
  is `is_not_empty`, and `NOT LIKE '%'` `is_empty`, instead of `contains
  ""` or an error.
- A `nil` in a list, `where(P: [a, nil])`, means empty, as
  `where(P: nil)` does; it used to be sent as `""`, which Notion rejects
  for a date.
- `order(..., nulls: :first)` raises instead of being dropped; Notion
  always sorts empty values last.
- `update` with SQL (`Sequel.lit`) raises `Sequel::Error` instead of a
  `NoMethodError`.
- A file of a type the adapter does not know reads back as a
  `Sequel::Notion::File` keeping its `raw` hash, and is written back
  unchanged, instead of making the whole page unreadable; two such files
  compare by that hash, since they may have no URL. `File.new` refuses an
  unknown keyword.
- `transaction(rollback: :always)` raises instead of keeping every write;
  `rollback: :reraise` re-raises `Sequel::Rollback`.
- Upper-case page and data source ids are lower-cased, which Notion
  requires, including an id given to `register_data_source`: it used to
  make every query 404, `table_exists?` false and id lookups empty.
- A raw `NOT` over a date equality is `before or after` instead of a
  `does_not_equal` Notion rejects.
- A date with an end reads back as a `Range` of the two ISO 8601
  strings, which a write takes as is, instead of its start alone.
- A lock (`for_update`) on a join or a combined query raises, as on any
  other query, instead of being dropped.

## 0.1.0

- First version.
