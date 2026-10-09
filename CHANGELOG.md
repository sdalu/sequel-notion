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
- Table names keep non-Latin letters (`"タスク"` → `:タスク`) instead of
  normalising them all to the same empty name, which made a name lookup
  pick another data source and broke `register_all_data_sources`. A
  title with no letter or digit is named by its id, and a search that
  matches two data sources raises.
- An exclusive date `Range` ends on the day before; an exclusive `Time`
  range raises.
- A property named `id` or `in_trash` raises instead of overwriting the
  page's own column.
- `where(id: [a, a])` gives one row.

## 0.1.0

- First version.
