# Command-line switching

Switching an account is a two-click job in the menu bar, which makes it awkward
to drive from a script — a wrapper around `claude` that wants a specific Team,
a cron job that rotates accounts, a shell alias per project. This adds a
one-command path to the same operation.

Two layers:

| Layer | What it is | Who needs it |
|---|---|---|
| `ccswitcher://` URL scheme | Handled by the app itself (`URLCommandHandler`) | Everyone with the app installed — zero setup |
| `scripts/ccswitcher` | Thin Python wrapper: fires the URL, waits for the result, exits with a real code | Anyone scripting against it |

The switch always runs **inside the app**, through the same `AppState.switchTo`
the menu uses. That is deliberate:

- The backup-before-swap, the post-swap verification against `claude auth
  status`, and the in-app state update all come for free.
- The keychain sees the application it already trusts. A separate binary
  touching `Claude Code-credentials` or the backup item would trigger an
  authorization prompt on every machine.

## URL commands

```
ccswitcher://use?account=<label|org|email>[&nonce=<n>]
ccswitcher://use?id=<account-uuid>[&nonce=<n>]
ccswitcher://current[?nonce=<n>]
ccswitcher://list[?nonce=<n>]
```

`account` matches the custom label, the organization (Team) name, the display
name or the email — case-insensitively, exact match first, then substring.
**An ambiguous query is refused, never guessed**: the command swaps
credentials, so "probably this one" is the wrong failure mode.

```bash
open -g "ccswitcher://use?account=Work"
```

## Result file

`open` returns as soon as the URL is delivered, so the outcome is written to
`~/.ccswitcher/cli-result.json` (mode 600):

```json
{
  "nonce": "7fac30a2fe01…",
  "action": "use",
  "ok": true,
  "account": { "id": "…", "label": "Work", "email": "…", "orgName": "…", "orgId": "…", "active": true },
  "warning": "…",
  "error": null,
  "finishedAt": "2026-09-03T02:53:02Z"
}
```

The `nonce` is echoed back from the request. A caller that does not check it
can read another caller's answer, so the wrapper polls for its own nonce.

`ok: true` with a `warning` is a real case: the swap happened, but the CLI
resolves credentials from something that outranks the stored login (an
`ANTHROPIC_AUTH_TOKEN`, an `apiKeyHelper`, a third-party provider), so the
account will not actually be used.

## The wrapper

```bash
ln -sf "$PWD/scripts/ccswitcher" ~/.local/bin/ccswitcher

ccswitcher                 # list accounts, ★ marks the active one
ccswitcher current         # prints just the label
ccswitcher use Work        # switch, exit 0 only when it landed
ccswitcher use Work --json
```

Exit codes: `0` ok, `1` usage/no match/ambiguous, `2` app unreachable or timed
out, `3` the switch did not take effect.

```bash
ccswitcher use Work && claude -p "…"
test "$(ccswitcher current)" = "Work" || ccswitcher use Work
```

The swap is global and immediate: a `claude` session that is already running
bills its next API call to the new account. Finish or park what is in flight
before switching.
