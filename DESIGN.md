# Design

## A Sequel adapter with no SQL in it

`Sequel::Notion::Database` and `Sequel::Notion::Dataset` subclass Sequel's,
so that `DB[:tasks]`, `Sequel::Model` and the rest of Sequel's API work
unchanged. Below that layer nothing is SQL: the dataset reads its own
`@opts` (`:where`, `:order`, `:limit`, `:offset`, `:select`) and turns
them into Notion requests. `select_sql` returns a placeholder because
Sequel renders it before every fetch, and a real rendering would fail on
values SQL cannot express. `fetch_rows` refuses any SQL other than that
placeholder.

Two Sequel optimisations assume SQL, and both are turned off. Cached
loaders (`first(...)` called repeatedly, `Model[...]`) replace WHERE with
SQL placeholders, so `supports_placeholder_literalizer?` is false.
`Sequel::Model` precomputes primary-key lookup and delete SQL for a
"simple" table, so `ModelSupport` (prepended to `Sequel::Model`'s class
methods) never lets a model over a Notion dataset be simple. Its lookups
and deletes go through `where(id:)`. The dataset's own helpers are named
`each_notion_page` and `notion_page_size`, so Sequel's pagination
extension, which defines `each_page`, can sit on top.

Clauses Notion cannot express (`join`, `group`, `having`, `distinct`,
unions, locks) raise instead of being dropped. A query that silently
returns the wrong rows is worse than one that refuses to run.

## Where expressions are compiled

`FilterCompiler` (`lib/sequel-notion/filter_compiler.rb` and its
`filter_*` helpers) walks Sequel's expression tree and emits Notion filter
JSON. It needs each property's Notion type, because the filter key, and
for formulas the nested key, depend on it. The type map comes from the
data source object, which `Database` fetches once per data source and
caches. The same fetch feeds `schema`, through Sequel's
`schema_parse_table` hook, so Sequel's own schema cache works.

The compiler accepts Sequel's own shapes rather than re-deriving SQL:
`col => true` arrives as `IS TRUE`, `col => [...]` as `IN`, and a literal on
the left (`5 < n`) is mirrored. `exclude` arrives already inverted by
Sequel. The explicit `negate` table covers the `NOT` that survives, and an
operator with no Notion inverse (`starts_with`) raises.

## Writes are typed by the schema

`TypeMap.row_to_properties` takes the property type map and builds each
value for its Notion type. The Ruby value's class does not decide the
payload: a `String` is a title, a status, a URL or a date depending on the
column. Clearing a column uses the value Notion documents for that type
(`[]`, `null` or `false`), not an empty object.

Computed properties are refused on write, and the schema marks them
`generated`, which is what Sequel's `skip_saving_columns` plugin reads.
That keeps the refusal for an explicit write while letting a model's full
`save` work. Date columns get the schema type `:notion_date`, for which
Sequel has no typecast, because `:date` or `:datetime` would drop the time
or force one. Numbers other than Integer and Float are sent as Float,
because JSON would otherwise carry a BigDecimal or Rational as a string.

## Ids are collected before writing

`update` and `delete` gather the matching page ids first, then patch.
Patching while paginating would let a page that leaves the filter shift
the cursor and skip rows.

`where(id: …)` is served by `GET pages/{id}` rather than a query, because
the page id is not a filterable property. This, with the SQL paths turned
off above, is what makes `Sequel::Model` work: its reload, update and
delete all address one row by primary key. Id conditions under AND
intersect. Mixing an id with other conditions raises rather than
filtering client side. A page fetched by id is kept only if its parent is
this data source. It is kept even when trashed, because an id lookup is
the only way to reach a trashed page and restore it.

## Connections, retries, errors

Each pooled connection is a Faraday client. All requests go through
`Database#request`, which takes a pooled connection, logs through
Sequel's `log_connection_yield`, and re-raises Faraday errors as
`Sequel::DatabaseError` with Notion's `code: message`.

`raise_error` is declared outside `retry` in the middleware stack, so the
retry middleware sees a 429 as a status (and honours `Retry-After`) before
it becomes an exception. POST is not in the retry methods. `RETRY_IF`
allows a POST retry unless the request creates a page and the failure was
not a 429. A query or search is safe to repeat; a page creation that timed
out may already have happened.

Notion has no transactions. `transaction` just yields, so the
`Sequel::Model` paths that wrap a save in one still work. Nothing is rolled
back.

## Table names

`Registry` resolves a table name to a data source id: explicit
registration, then one-time discovery (`auto_register`), then an id used
directly, then a search. All of these name data sources through the same
`Registry.normalize`, so a search and a bulk registration agree on what
`"My Tasks"` is called. Rebinding a name to a different id raises,
because two Notion sources that normalise alike would otherwise shadow
each other silently. For the same reason, a search that finds two sources
under one name raises instead of taking the first.

`normalize` drops combining marks only after a Latin letter, where they
are accents (`É` → `e`). In other scripts a mark changes the letter
(Japanese `ガ` against `カ`, Cyrillic `й` against `и`), so those titles keep
their marks and their letters. A title with nothing left after
normalising is named by its id, because an empty name would match every
other empty one. Bulk registration validates every name before
storing any, and a discovery that fails is retried on the next lookup.
