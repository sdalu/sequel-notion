# History

Approaches tried and abandoned, so they are not proposed again.

## Choosing the payload from the Ruby value

The first write path picked the Notion payload from the value's class: a
`String` became `rich_text`, an `Array` became `multi_select`, `nil`
became `{}`. Notion requires the payload key to match the property type,
so writing a title, status, select, URL, relation or people property was
rejected, and so was every `nil`. Writes are now typed by the data
source's schema (see DESIGN.md).

## `retry` outside `raise_error`

The Faraday stack first declared `retry` before `raise_error`. That made
`raise_error` the inner middleware, so a 429 became a
`Faraday::TooManyRequestsError` before `retry` could see the status. That
exception is not among faraday-retry's default exceptions, and POST was
not among its default methods either. Nothing was ever retried, including
every query and search. The order is now reversed and the methods are
explicit. `test_rate_limit_is_retried` watches a 429 being retried.

## ASCII-only table names

Titles were first reduced to `[a-z0-9_]`. Every title in a non-Latin
script became the empty name, so the search fallback bound a table to
whichever such data source came first, and `register_all_data_sources`
failed on any two of them. Stripping every combining mark, the obvious
way to keep other scripts, would merge distinct Japanese and Cyrillic
letters. Marks are now dropped only after Latin letters (see DESIGN.md).

## Marking discovery done before running it

`auto_register` first set its flag under the lock and then ran the
discovery, resetting the flag if it failed. A second thread arriving
meanwhile saw the flag, skipped discovery, and answered from the
registry as it stood: `DB.tables` returned `[]`. The flag is now set
after the discovery succeeds (see DESIGN.md);
`test_tables_never_answer_from_a_discovery_in_flight` holds a discovery
open in one thread and asks from another.

## Discovery as an all-or-nothing bulk registration

`auto_register` first ran `register_all_data_sources`, which refuses
the whole set when two sources share a name. In a workspace where two
data sources normalised to `property`, every lookup raised, including a
data source id and every unrelated name, and each one repeated the full
search. Discovery now marks only the shared name ambiguous, and an id
resolves before discovery (see DESIGN.md).
`test_a_discovered_clash_spares_the_other_names` holds it.

## Putting `:id` first in selected rows

Selected rows used to carry `:id` first, so that `update` and `delete`
could find their pages. Sequel's `get` and `select_map` take the first
value of a row, so `get(:Name)` returned the page id. Writes now collect
ids from the full pages, and selected rows hold only what was selected.
