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

Notion sorts by a property or a timestamp, never by page id, so ordering
by `:id` raises, and `ModelOrderSupport` stops a model from adding its
primary key order to `last` and `paged_each`. Mapping `:id` to the
creation time or to a `unique_id` property was rejected: it reads one
column as another, and creation times tie. `paged_each` streams through
Notion's cursor instead of Sequel's `OFFSET` pages, which the adapter
can only honour by re-reading every page skipped; Sequel's postgres
adapter does the same through `use_cursor`, which needs no order.

Clauses Notion cannot express (`join`, `group`, `having`, `distinct`,
unions, locks) raise instead of being dropped. A query that silently
returns the wrong rows is worse than one that refuses to run.

## Where expressions are compiled

`FilterCompiler` (`lib/sequel/notion/filter_compiler.rb` and its
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

`nil` means empty wherever it appears: `where(P: nil)` is `is_empty`, and
so is a `nil` inside a list, `where(P: [a, nil])`. SQL's `IN` never
matches `NULL`, but the adapter has no `NULL` to be faithful to, and
passing `nil` on as a value sent `""`, which Notion matches as empty for
some types and rejects for others (a date answers 400).

Negations follow SQL's rule for empty values, where `N != 1` never
matches a `NULL` (checked live: Notion's `does_not_equal` and
`does_not_contain` match an empty property, while the date `!=`, written
`before or after`, did not). `FilterNulls` adds `is_not_empty` beside
each such leaf once the filter is finished: negation has to run first,
or `NOT (N != 1)` would negate the guard into `is_empty`. Following
Notion's rule instead was rejected: a Sequel user reads `exclude` as
SQL, and the date `!=` already followed SQL. Formula and unique ID
leaves need no guard: Notion leaves an empty formula result out of its
negations (checked live), and a unique ID is never empty.

The guard adds a level, and Notion nests `and`/`or` two levels deep at
most, so `FilterShape` merges an `and` inside an `and` and distributes a
level too many into clauses (`(a & b) | c` as `(a | c) & (b | c)`), up
to 32 of them; deeper filters raise rather than earn a 400.

A `LIKE` pattern of wildcards only matches any non-null string, which in
Notion is `is_not_empty`; sending it as `contains ""` would leave the
answer to whatever Notion does with an empty needle.

Sorts can only describe what Notion does. Notion puts empty values last
in both directions (checked live), so `nulls: :last` is accepted as a
no-op and `nulls: :first` raises.

## Truncated lists are completed on read

A page object lists at most 25 relations or people. `DatasetTruncation`
completes such a property from the page property endpoint while a row is
read, and only for the columns the query returns, so a `select` that
leaves it out costs nothing. A relation says `has_more`; people carry no
flag, so 25 of them are read again in case there are more, which costs a
request when there were exactly 25. Leaving the truncation to the reader
was rejected: a row is the only place a caller looks, and a silently
short list is a wrong result. Mentions inside a title or rich text are
also cut at 25 but unflagged and rare, and are not completed.

## Writes are typed by the schema

`TypeMap.row_to_properties` takes the property type map and builds each
value for its Notion type. The Ruby value's class does not decide the
payload: a `String` is a title, a status, a URL or a date depending on the
column. Clearing a column uses the value Notion documents for that type
(`[]`, `null` or `false`), not an empty object.

Computed properties are refused on write, and the schema marks them
`generated`, which is what Sequel's `skip_saving_columns` plugin reads.
That keeps the refusal for an explicit write. A model's `save` of a
loaded record sends only the changed columns (`ModelSaveSupport`), not
Sequel's default of every column: a row reads rich text back as plain
text, and writing it back unchanged would destroy the formatting. Date columns get the schema type `:notion_date`, for which
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
back. The one option it cannot ignore is `rollback: :always`: a caller
passing it (a test suite wrapping each test, typically) relies on the
writes disappearing, so it raises before the block runs rather than keep
them.

## Table names

`Registry` resolves a table name to a data source id: explicit
registration, then an id used directly, then one-time discovery
(`auto_register`), then a search. An id comes before discovery so that
it never waits on, or fails with, a listing it does not need. All of
these name data sources through the same `Registry.normalize`, so a
search and a bulk registration agree on what `"My Tasks"` is called.
Rebinding a name to a different id raises, because two Notion sources
that normalise alike would otherwise shadow each other silently. For the
same reason, a search that finds two sources under one name raises
instead of taking the first.

Discovery applies that rule per name, as Go does for an ambiguous
selector and Java for a simple name two on-demand imports provide: the
error comes where the shared name is used, not where it is declared. A
name two discovered sources share is stored as `Registry::Ambiguous`,
which raises on lookup and is left out of `tables`; every other name
registers. A registration may replace that marker, and discovery never
overwrites a name already registered: an explicit binding is a choice,
not a shadow. An explicit `register_all_data_sources` stays all or
nothing, because its caller named the set and can pass a mapper.

Notion's search keeps listing a trashed data source, flagged `in_trash`
(checked live). Every path that names sources from a listing skips those,
so a trashed copy neither makes a live source's name ambiguous nor binds
a name to a source that cannot be queried. `data_sources` returns the
listing unfiltered, since the flag is part of what it reports.

`normalize` drops combining marks only after a Latin letter, where they
are accents (`É` → `e`). In other scripts a mark changes the letter
(Japanese `ガ` against `カ`, Cyrillic `й` against `и`), so those titles keep
their marks and their letters. A title with nothing left after
normalising is named by its id, because an empty name would match every
other empty one. A discovery that fails is retried on the next lookup.

Discovery follows Sequel's own schema cache: check the flag under
`Sequel.synchronize`, run the requests with no lock held, and set the
flag only once they succeed. `Sequel.synchronize` is one process-wide
mutex, so holding it across HTTP would stall every Sequel thread. Threads
that start together on a cold connection each run the discovery, which
costs requests but never lets one of them answer from a registry half
filled.
