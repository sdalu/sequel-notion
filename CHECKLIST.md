# Closing a round on sequel-notion

## Gates

Run in order.

- [ ] `bundle exec rake test` — the whole suite, green
- [ ] `rubocop -c ~/.claude/skills/ruby/scripts/rubocop.yml lib` — no offences
- [ ] `for f in lib/*/*.rb lib/*/*/*.rb; do ruby -wc "$f"; done` — no warnings

## Documents

- [ ] `README.md` — does every option, method and filter mapping it names
      still exist, and is a new limitation under Known shortfalls?
- [ ] `DESIGN.md` — is a decision this round took written down, with the
      alternative it rejected?
- [ ] `HISTORY.md` — did this round abandon something (add it), or remove
      what an entry explains (delete the entry)?
- [ ] `CHANGELOG.md` — is the change under the unreleased version?

## Release

- [ ] Does the number move? It lives in `lib/sequel/notion/version.rb`
      only; the CHANGELOG heading must match it.
