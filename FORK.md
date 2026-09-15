# Working on this fork

This is `roc-zjp/CCSwitcher`, a fork of `XueshiQiao/CCSwitcher` that is developed
**independently**: upstream merges PRs slowly, so features land here first and
nothing is pushed back upstream. Upstream changes flow one way — in.

## Branch model: one line, `main`

Everything lives on `main`. Not one branch per feature — features scattered
across `feat/*` branches is exactly how a build ends up quietly missing things
that were finished weeks ago.

```
origin/main   upstream, read-only          ──┐  merged in periodically
fork/main     this fork's development line ──┴──────────────────────────▶
local/team-id main + the local signing patch (never pushed)
```

Use short-lived branches only when something genuinely needs isolating, and
merge them into `main` the same day. A branch that outlives its feature is a
branch whose work gets forgotten.

## Pulling in upstream changes

```bash
git fetch origin
git checkout main
git merge origin/main        # resolve conflicts, keep our versions of ours
./scripts/rebuild-local      # re-stack the signing patch and build
git push fork main
```

Never `git push origin` — pushing upstream is not part of this workflow.

## The signing patch

`project.yml`, both `.entitlements` files, and `Shared/WidgetData.swift` carry
the upstream author's Apple Team ID (`584KQTRF3B`) and the App Group derived
from it. Building locally requires ours instead, so `local/team-id` holds a
single commit swapping them, kept on top of `main` and never pushed.

It stays a separate commit rather than being merged into `main` for two
reasons: a Team ID is per-developer configuration, not a feature, and keeping
it as the tip commit makes it trivial to re-stack after every upstream merge.

```bash
git checkout local/team-id
git rebase main              # carries the patch onto the new main
```

`scripts/rebuild-local` does this and builds in one step.

The permanent fix is to move the Team ID out of tracked files entirely (an
xcconfig plus `$(AppIdentifierPrefix)` in the entitlements, with the App Group
injected into Info.plist rather than hard-coded in `WidgetData.swift`). Worth
doing, but it touches the App Group — get it wrong and widget data sharing
fails silently — so it needs a real install to verify, not just a green build.

## Building

```bash
xcodegen generate            # after ANY project.yml change
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Release build
```

Signing needs an `Apple Development` certificate for the team in `project.yml`.
If the private key is missing, regenerate it in Xcode → Settings → Accounts →
Manage Certificates → + → Apple Development. To check compilation only, without
a certificate:

```bash
xcodebuild ... build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

## Fork-only features

These do not exist upstream — check here before assuming a behavior is theirs:

| Feature | Docs |
|---|---|
| Command-line switching (`ccswitcher use Work`, `ccswitcher://` URL scheme) | [docs/cli.md](docs/cli.md) |
| Quota pre-warming (open the 5-hour window before the workday) | [docs/prewarm.md](docs/prewarm.md) |
| Multi-org support (same email across several Teams) | — |
| Launch-time bootstrap fix, parse-cache write reduction | — |
