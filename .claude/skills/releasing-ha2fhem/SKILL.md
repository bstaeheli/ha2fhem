---
name: releasing-ha2fhem
description: Use when cutting, tagging, publishing or rolling out a new ha2fhem version, or when the user says "release", "neue version", "ausrollen", "v0.x.y", or asks how ha2fhem reaches Home Assistant.
---

# Releasing ha2fhem

Codeberg is the origin; GitHub is a converted mirror that carries the
releases; HACS is the only way the code reaches Home Assistant.

## Delegate the run

This is a mechanical checklist, so hand it to a cheaper model instead of
running it in the main thread:

```
Agent(subagent_type="general-purpose", model="sonnet",
      description="Release ha2fhem vX.Y.Z",
      prompt="Read .claude/skills/releasing-ha2fhem/SKILL.md in
              /home/dev/scm/ha2fhem and execute it for version X.Y.Z.
              Report each step's result, and stop and report if any
              gate fails.")
```

Use `model="haiku"` for a pure patch release with no code review needed.
The main thread still decides the version number and reviews the diff
before delegating — the subagent does not judge whether the release is
ready.

## Never deploy to Home Assistant by hand

**Home Assistant is updated through HACS only.** Do not `scp`, `rsync`,
`tar`, `ssh` or otherwise write into `/config/custom_components/ha2fhem`
on the production HA (10.21.30.42), and do not restart HA to activate
code you copied there.

No exceptions:
- Not "just this once to test it"
- Not "HACS is slower"
- Not because a manual copy is already there from an earlier release
- Not even with the user's SSH key working and `sudo` available

HACS installs integrations into that very directory, so a hand-copy does
not create a second install — it overwrites HACS's files behind its back
and corrupts its bookkeeping: `installed_version` in
`/config/.storage/hacs.data` goes `None`, and HACS can no longer tell
what is actually on disk or offer a correct update. Repairing that is a
redownload through the HACS UI, which only the user can trigger.

Publishing the GitHub release **is** the deployment. What you may do on
request is drive HACS itself — that goes through HACS's bookkeeping, so
it is the sanctioned path, not a workaround:

1. HACS only refreshes downloaded custom repositories **every 48 hours**
   and not at startup, so a fresh tag stays invisible. Force it over HA's
   websocket API (`ws://<host>:8123/api/websocket`, auth with `HA_TOKEN`,
   admin required):
   `{"id":1,"type":"hacs/repository/refresh","repository":"<repo id>"}`
   — `repository` is HACS's numeric id (`1292217807` for ha2fhem, found
   in `/config/.storage/hacs.data`). This runs `update_repository(force=True)`,
   which bypasses the cached `etag_repository`. Reloading the HACS config
   entry does **not** do this.
2. `update.ha2fhem_update` then flips to `on` with the new
   `latest_version`. Install with the ordinary HA service
   `update/install` on that entity — HACS does the download itself.
3. Restart HA (`homeassistant/restart`) so the new modules load, then
   confirm `version_installed` in `hacs.data` matches the new tag.
   HACS writes that file on shutdown, so before the restart it still
   shows the old version even though the update succeeded.

## Gates — all must pass before tagging

| Gate | Command |
|---|---|
| FHEM tests | `prove -r tests/fhem` |
| HA tests | `<venv>/bin/python -m pytest tests/ -q` (no system pytest; make a venv) |
| Version bumped | `custom_components/ha2fhem/manifest.json` |
| Translations in sync | `diff custom_components/ha2fhem/strings.json custom_components/ha2fhem/translations/en.json` must be empty |
| Docs match config surface | `custom_components/ha2fhem/README.md` table lists every config-flow field |

`strings.json` and `translations/en.json` are the same file by convention.
Editing only one is the easiest mistake in this repo — it has already
shipped broken once.

## Steps

```bash
cd /home/dev/scm/ha2fhem          # required: .envrc is sourced relatively
set -a; . ./.envrc; set +a        # never silence stderr here
test -n "$HA_URL" || exit 1       # proves the sourcing actually worked

git commit                        # ends with the Claude-Session trailer
git tag -a vX.Y.Z -m "..."
git push origin main && git push origin vX.Y.Z
sh tools/mirror-to-github.sh      # SHA-256 -> SHA-1 conversion, force-push
```

Then create the GitHub release via REST (`GITHUB_MIRROR_REPO` /
`GITHUB_MIRROR_TOKEN` from `.envrc`), `POST /repos/{repo}/releases` with
`tag_name`, `name`, `body`. Verify afterwards that
`/repos/{repo}/contents/custom_components/ha2fhem/manifest.json?ref=vX.Y.Z`
reports the new version — that is what HACS will fetch.

**Codeberg releases do not work.** The repo uses the SHA-256 object
format; Codeberg's release API answers "target couldn't be found". Push
the tag there, but create the release only on GitHub. Do not spend time
retrying Codeberg.

## Common mistakes

| Mistake | Consequence |
|---|---|
| `cd`ing away from the repo root mid-session | `. ./.envrc` fails silently, env vars are empty, and commands hit empty URLs while looking like timeouts |
| Silencing stderr on `. ./.envrc` | Hides the failure above; always `test -n "$HA_URL"` after sourcing |
| Updating `translations/en.json` only | `strings.json` ships stale labels |
| Assuming a config-entry reload picks up new code | It does not reload Python modules; only an HA restart does — and the user does that after their HACS update |
| Forgetting `tools/mirror-to-github.sh` | Tag exists on Codeberg, HACS sees nothing |
