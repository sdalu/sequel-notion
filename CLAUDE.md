# sequel-notion — session entry

- Gate: `bundle exec rake test` (after `bundle install`). Run it before
  and after a change. Close a round with CHECKLIST.md.
- README.md: what the adapter does. DESIGN.md: why it is shaped so.
  HISTORY.md: what was tried and dropped.
- Style: the house RuboCop config, `~/.claude/skills/ruby/scripts/rubocop.yml`.
- Trap: the suite never reaches api.notion.com; it stubs Notion with
  Faraday's test adapter (`faraday_adapter: [:test, stubs]`). A green run
  proves the payloads match what the code believes about Notion, not what
  Notion accepts. README's "Checked against the live API" section lists
  what was checked live; anything else rests on stubs only. The Ruby
  side is checked against SQLite instead (`test/sql_oracle.rb`): a query
  shape added there gets a case in `test_sql_oracle.rb`.
- Trap: `faraday-retry` is a separate gem and is not installed
  system-wide here, so plain `rake test` fails with a LoadError. Use
  `bundle exec`.
- Trap: Sequel hands the compiler its own shapes: `col => true` is `IS`,
  `exclude` is already inverted, and a literal on the left is wrapped.
  Probe a new case with `Sequel.mock[:t].where(...).opts[:where]` before
  writing a rule for it.
