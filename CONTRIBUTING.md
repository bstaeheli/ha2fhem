# Contributing to ha2fhem

Thanks for your interest! This project is community-driven and lives on
[Codeberg](https://codeberg.org/bstaeheli/ha2fhem).

## Ground rules

- **`CONTRACT.md` is the source of truth.** Any change to topics or payload
  schemas gets its own reviewed commit — never a silent drift inside a
  feature change.
- **New device class = new profile, never module-core surgery.** If adding a
  device class requires touching the FHEM module core, that is a bug in the
  abstraction — open an issue instead.
- **Both sides validate against the same example payloads.** The HA side
  publishes only contract-valid payloads; the FHEM side tests against them.
- Each phase/milestone must leave the project runnable and demoable.

## Workflow

1. Pick an issue (look for `help wanted` / `good first issue`) or open one.
2. Discuss approach in the issue before large changes.
3. Fork, branch, PR against `main`.

## Language

English preferred for issues, PRs and code comments — German is fine too
(the FHEM community is German-heavy, we get it).

## License

By contributing you agree your work is licensed under GPL-2.0.
