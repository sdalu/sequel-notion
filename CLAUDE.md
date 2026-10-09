# sequel-notion — session entry

- Gate: `bundle exec rake test` (after `bundle install`, which installs
  into `vendors/`). Run it before and after a change. Close a round with
  CHECKLIST.md.
- README.md: what the adapter does. DESIGN.md: why it is shaped so.
  HISTORY.md: what was tried and dropped.
- Style: the house RuboCop config, `~/.claude/skills/ruby/scripts/rubocop.yml`.
- Trap: the suite never reaches api.notion.com; it stubs Notion with
  Faraday's test adapter (`faraday_adapter: [:test, stubs]`). A green run
  proves the payloads match what the code believes about Notion, not what
  Notion accepts. README's Known shortfalls lists the claims not yet checked
  against the live API.
- Trap: `faraday-retry` is a separate gem and is not installed
  system-wide here, so plain `rake test` fails with a LoadError. Use
  `bundle exec`.
- Trap: Sequel hands the compiler its own shapes: `col => true` is `IS`,
  `exclude` is already inverted, and a literal on the left is wrapped.
  Probe a new case with `Sequel.mock[:t].where(...).opts[:where]` before
  writing a rule for it.
