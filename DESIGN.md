# Design

## A Sequel adapter with no SQL in it

`Sequel::Notion::Database` and `Sequel::Notion::Dataset` subclass Sequel's,
so that `DB[:tasks]`, `Sequel::Model` and the rest of Sequel's API work
unchanged. Below that layer nothing is SQL: the dataset reads its own
`@opts` (`:where`, `:order`, `:limit`, `:offset`, `:select`) and turns
them into Notion requests. `select_sql` returns a placeholder because
Sequel renders it before every fetch, and a real rendering would fail on
values SQL cannot express. `fetch_rows` refuses any SQL other than that
placeholder, so `with_sql` raises: there is no SQL to run. Every other
path that would run SQL (`run`, `<<`, `truncate`, the `with_sql_*`
writes, schema changes) ends in `Database#execute`, which raises
`Sequel::Error`; `order(Sequel.lit(...))` raises too, though a literal
is a `String`, which would otherwise read as a property name.

Two Sequel optimisations assume SQL, and both are turned off. Cached
loaders (`first(...)` called repeatedly, `Model[...]`) replace WHERE with
SQL placeholders, so `supports_placeholder_literalizer?` is false.
`Sequel::Model` precomputes primary-key lookup and delete SQL for a
"simple" table, so `ModelSupport` (prepended to `Sequel::Model`'s class
methods) never lets a model over a Notion dataset be simple. Its lookups
and deletes go through `where(id:)`. The dataset's own helpers are named
`each_notion_page` and `notion_page_size`, so Sequel's pagination
extension, which defines `each_page`, can sit on top.

## Ordering and paging follow Notion

Notion sorts by a property or a timestamp, never by page id, so ordering
by `:id` raises, and `ModelOrderSupport` stops a model from adding its
primary key order to `last` and `paged_each`. Mapping `:id` to the
creation time or to a `unique_id` property was rejected: it reads one
column as another, and creation times tie. `paged_each` streams through
Notion's cursor instead of Sequel's `OFFSET` pages, which the adapter
can only honour by re-reading every page skipped; Sequel's postgres
adapter does the same through `use_cursor`, which needs no order.

## Computed in Ruby, behind `client_side`

Notion's API computes no aggregate, `distinct`, group, combination of
queries or join. The adapter computes them in Ruby over the rows the
queries return, as `offset` and `count` already were: the result is
SQL's, and the cost is reading every matching row, which the README
states. Notion still does what it can express: each `where` condition
is sent with the query of the table it tests, and rows arrive through
its cursor.

```text
┌─ Notion, one query per table ───┐    ┌─ Ruby, under client_side ──────┐
│ where: each condition sent with │    │ join: match on one equality    │
│   the table it tests            ├───▸│ group, having, aggregates      │
│ rows: 100 per request, through  │    │ distinct, DISTINCT ON          │
│   the cursor                    │    │ union, intersect, except       │
└─────────────────────────────────┘    │ offset, limit over the result  │
                                       └────────────────────────────────┘
```

These operations run only on a dataset that asks with `client_side`;
otherwise they raise before the first request. A join or a sum is
written like any other query, and nothing in it shows that it will read
whole data sources at about 3 requests a second; the opt-in makes the
caller say so. Opt-in was chosen over a default request budget because
a refusal costs nothing and happens before the first request, whereas a
budget stops a query that is already running and has already spent its
requests. Running computed operations by default, as `offset` and
`count` already read every page, was the rejected alternative.

`client_side(max_requests: n)` adds a ceiling for a caller who wants
one, and accepting a stop in the middle of a query is that caller's
choice. `RequestBudget` counts every request of the query that Notion
answers with a 200, nested queries included (both tables of a join,
both sides of a union, the schema fetch), and raises before the request
past it. The count is taken above faraday-retry, after the answer: a
429 is Notion asking the client to wait, not work the query did, so the
attempts a retry absorbs spend nothing, and neither does a request that
fails (a page by id that is gone). Counting every HTTP attempt was
rejected: a throttled query would then fail on Notion's load rather than
on its own size. The budget is a thread-local, so it is set aside while
each row is handed to the caller: a query the caller runs on that row is
its own, while the queries the adapter runs inside (a join's tables, a
union's sides) still spend the one budget.

`group` keeps one running value per aggregate per group
(`GroupAccumulator`) rather than the group's rows, so memory grows with
the number of groups, not of rows. `having`
is evaluated over the groups with SQL's three-valued logic, an aggregate
it writes out being computed as a hidden output. `DISTINCT ON` keeps the
first row of each key; `union`, `intersect` and `except` read each
query's rows and combine them as SQL does.

Joins are inner or left, on one equality, matched in Ruby with a hash on
the joined side, whose rows are held in memory. Each `where` condition
is sent with the query of the one table it tests (`JoinWhere`); one that
tests two tables has no Notion filter and raises rather than be
evaluated over every pair. A relation is an Array of page ids, so an
equality with it matches every id it lists: that is what makes
`join(:projects, id: :Project)` follow the relation. Aggregates and
groups read columns under hidden names (`:__value`, `:__c0`), so a
qualified column keeps its table through them.

Sending a condition with its table's query is `WHERE` on an inner join,
but on a left join it is `ON`: a row whose partner fails it was kept,
its joined side empty. A left join's own conditions therefore filter
its partners after matching: the table is queried whole to find each
row's partners, and with the conditions to know which pass. A row with
no partner is kept if an empty page passes the compiled filter, which
only an `is_empty` test does, negations carrying `is_not_empty`: SQL's
rule for a `NULL` row, decided by the same filter Notion runs, rather
than by a Ruby evaluator of Sequel expressions that would have to
reproduce every Notion operator. Raising on such a `where` was
rejected: `left_join(...).where(right: nil)` is the usual anti-join,
and the second query is the whole cost.

What neither Notion nor Ruby computes raises instead of being dropped:
locks (on every path, the computed ones included), raw SQL (`with_sql`),
right, full and cross joins, a join `ON` other than one equality, a
`where` condition testing two joined tables, `INTERSECT ALL` and
`EXCEPT ALL`, a subquery in `FROM` that combines nothing (`from_self`),
and a `where`, `group`, `having`, `distinct` or join added to a combined
query. A `select` added to one projects the combined
rows, since `select_map` and `get` add one. A query that silently
returns the wrong rows is worse than one that refuses to run.

## The suite checks the Ruby side against SQLite

The suite stubs Notion, so it cannot say whether what the adapter
computes in Ruby gives SQL's answer; a hand-written expected value only
says what its author believed. `test/sql_oracle.rb` puts the same rows
in a stubbed Notion, which filters and sorts as Notion does (an empty
value matching `does_not_equal`, sorting last), and in an in-memory
SQLite database. `test_sql_oracle.rb` runs aggregates, groups, `having`,
`distinct`, compounds and joins, over numbers, text, dates and selects,
on both, and `test_sequel_api_oracle.rb`
Sequel's own dataset methods, over 25 random data sets each; both must
agree. Restoring the left-join code this round fixed makes three of the
oracle's queries fail. Where Notion and SQL differ by design (empty
values sort last), the queries ask for that order on both sides.

## Where expressions are compiled

`FilterCompiler` (`lib/sequel/notion/filter_compiler.rb` and its
`filter_*` helpers) walks Sequel's expression tree and emits Notion filter
JSON. It needs each property's Notion type, because the filter key, and
for formulas the nested key, depend on it. The type map comes from the
data source object, which `Database` fetches once per data source and
caches. The same fetch feeds `schema`, through Sequel's
`schema_parse_table` hook, so Sequel's own schema cache works.
`refresh_schema!` drops both, and bumps the data source's epoch: a fetch
already in flight when it ran finds the epoch changed and fetches again,
rather than putting the old properties back over a fresh read.

The compiler accepts Sequel's own shapes rather than re-deriving SQL:
`col => true` arrives as `IS TRUE`, `col => [...]` as `IN`, and a literal on
the left (`5 < n`) is mirrored. `exclude` arrives already inverted by
Sequel. The explicit `negate` table covers the `NOT` that survives, and an
operator with no Notion inverse (`starts_with`) raises.

An empty list follows Sequel's SQL adapters, which send `IN ()` as
`1 = 0` and `NOT IN ()` as `1 = 1`. Notion has no such filter, so
`FilterConstants` stands for them while compiling: `and` and `or` fold
them away, `NOT` swaps them, and only a whole filter can be one: no
filter sent for every page, no request at all for none. Refusing an
empty list, the first behaviour, was dropped (HISTORY.md); Sequel's
`empty_array_consider_nulls` reading, under which neither matches an
empty property, was not taken because Sequel itself does not default to
it.

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
negations (checked live), and a unique ID is never empty. A rollup's
does: its `does_not_equal` matched an average over no relation (checked
live), so the guard goes under the rollup's kind, as the condition does.

A rollup filters through its value, nested like a formula's (rule R):
`{rollup: {number: …}}` or `{rollup: {date: …}}`. Which one is read from
the function in the data source schema, not from the value's class as a
formula's is, because Notion answers 400 when they disagree (checked
live). A rollup that keeps every value is filtered in Notion with
`any`, `every` or `none`, which a SQL comparison does not say, so it
raises.

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
text, and writing it back unchanged would destroy the formatting. Date
columns get the schema type `:notion_date`, for which Sequel has no
typecast, because `:date` or `:datetime` would drop the time or force
one. Numbers other than Integer and Float are sent as Float,
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
