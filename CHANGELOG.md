# Changelog

## 0.2.0 — unreleased

- Writes are typed by the data source schema (title, status, select,
  relation, people, date ranges, files), and `nil` clears a property.
- Filters: `IS TRUE/FALSE`, `IN`, `LIKE` patterns, formula properties,
  date `!=`, `Sequel[:col]` and qualified columns, bare checkbox columns.
- `where(id: …)` fetches pages directly; `Sequel::Model` works.
- `offset`, `count`, `empty?`, `get` and `select_map` fixed; joins and
  other unsupported clauses raise.
- 429 and 5xx responses are retried, honouring `Retry-After`; failures
  raise `Sequel::DatabaseError`; requests are logged.
- `Sequel::Model` works through Sequel's cached loaders and explicit
  primary keys; computed properties are `generated` for
  `skip_saving_columns`; dates are not typecast.
- Trashed pages are reachable by id and can be restored.
- `table_exists?`, the pagination extension and `Sequel::Rollback` work.
- Requires Ruby 3.4.
- Files live under `lib/sequel/notion/`, as RubyGems' naming guide asks
  of a dashed gem name, and `require "sequel/notion"` (or Bundler's
  auto-require) loads the adapter.
- Table names keep non-Latin letters (`"タスク"` → `:タスク`) instead of
  normalising them all to the same empty name, which made a name lookup
  pick another data source and broke `register_all_data_sources`. A
  title with no letter or digit is named by its id, and a search that
  matches two data sources raises.
- An exclusive date `Range` ends on the day before; an exclusive `Time`
  range raises.
- A property named `id` or `in_trash` raises instead of overwriting the
  page's own column.
- `where(id: [a, a])` gives one row, and an id matches itself written
  with or without dashes.
- With `auto_register`, a lookup or `tables` made while another thread
  is discovering runs its own discovery and gets a complete answer,
  instead of reading a half-filled registry.
- Text is split into runs of 2000 UTF-16 units, the length Notion
  checks, so a long text with emoji is no longer rejected.
- NaN and Infinity, in a write or a filter, and an external file URL that
  does not parse raise `Sequel::Error` instead of a JSON or URI error; a
  write names the property. A file URL with no path is named by the URL rather
  than `"/"` or `""`.
- A numeric string that overflows to Infinity (`"1e400"`) raises
  `Sequel::Error` too, instead of a JSON error.
- `where(F: true)` and `exclude(F: false)` on a checkbox formula filter
  through the formula's `checkbox` key instead of raising.
- `LIKE` with a wildcard on a multi-select, people or relation property
  raises: Notion's `contains` there matches a whole value, so `"%ruby%"`
  silently matched only the option `ruby`.
- With `auto_register`, two data sources sharing a name no longer break
  every lookup: only that name raises, until `register_data_source`
  picks one, and a data source id resolves without discovery.
- A bare formula column, `where(:F)` or `exclude(:F)`, filters on its
  checkbox result instead of raising.
- A `nil` in a list, `where(P: [a, nil])`, means empty, as
  `where(P: nil)` does; it used to be sent as `""`, which Notion rejects
  for a date.
- `order(..., nulls: :first)` raises instead of being dropped; Notion
  always sorts empty values last.
- Discovery, the search fallback and `register_all_data_sources` skip
  data sources in the trash, which Notion's search still lists.
- `register_data_source` keeps the id as a String, so registering the
  same id as a Symbol and as a String no longer raises, and discovery
  never overwrites it.
- A beginless date range raises `Sequel::Error` naming the property,
  instead of Notion's 400 on a null start.
- `update` with SQL (`Sequel.lit`) raises `Sequel::Error` instead of a
  `NoMethodError`.

## 0.1.0

- First version.
