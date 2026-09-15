# Quota pre-warming

Claude's 5-hour quota window is **not a fixed slot on the clock**. It is created
by an account's first request and expires five hours later — when there is no
activity, the window does not exist at all (the usage endpoint does not even
return a `resets_at` for it).

That makes the time of your first request the thing that decides where every
quota boundary of your day falls. Which means it is worth choosing deliberately.

## The problem

For a 9-to-6 day with lunch at 12:00:

```
first request at 09:00  →  window 09:00–14:00
                           ├─ 09:00–12:00  three hours of work
                           ├─ 12:00–13:00  lunch: the window drains with nobody using it
                           └─ 13:00–14:00  back at the desk, waiting for a window you already spent
```

The waste is not "too little quota" — it is an hour of dead time after lunch,
every day.

## The fix

Send one deliberately tiny request at **08:00**:

```
first request at 08:00  →  window ①  08:00–13:00   covers the whole morning,
                                                    expires exactly during lunch
                           window ②  13:00–18:00   opened by your first request
                                                    after lunch, covers the afternoon
```

Both windows now land entirely inside working hours. 08:00 beats 07:00 for the
same reason: a 07:00 window spends its first hour on an empty desk.

## How CCSwitcher does it

Settings → General → **Pre-warm**. Toggle it on, pick a time, optionally limit it
to weekdays.

Two properties worth knowing:

- **No account switching.** Every account is warmed with its own token — the
  active one from the keychain, the others from their backups — exactly the way
  usage polling already reads them. Your active account never changes, so a
  `claude` session running at 08:00 is unaffected. (A shell script cannot do
  this: it can only warm an account by switching to it, which silently
  redirects any in-flight session.)
- **The request is as small as the API allows**: `claude-haiku`, `max_tokens: 1`,
  one word in. 8 input tokens, 1 output token. Only the fact that a request
  happened matters — the content is irrelevant.

### Scheduling

Rather than firing a one-shot timer at 08:00, the app checks once a minute
whether it is past the scheduled time and whether today has already been warmed.
A one-shot timer assumes the Mac is awake and the clock is monotonic; sleeping
through the fire time, waking late, changing time zone, or relaunching the app
would each silently skip a day.

If the Mac was asleep at 08:00, the pre-warm happens on wake — but only within
**3 hours** of the scheduled time. Waking at 09:30 and igniting is still useful;
waking at 23:00 and igniting would open a window nobody is awake to use, and push
tomorrow morning's boundary into the evening.

The day is marked as warmed only once at least one account succeeded, so a run
that fails outright (offline, DNS not up yet) is retried on the next tick instead
of being written off until tomorrow.

The scheduling rules are pure functions in `PrewarmSchedule` so they can be
tested without waiting for 8am:

```bash
swiftc -o /tmp/prewarm-tests \
    CCSwitcher/Services/PrewarmSchedule.swift \
    Tests/PrewarmScheduleTests/main.swift
/tmp/prewarm-tests
```

## Verifying it worked

The window's existence is directly observable: when an account has no active
window, the usage response carries no reset time for it. In the app, the account
row simply shows no session countdown. After a pre-warm, a fresh
`0% · resets in 4h 5x` appears — that transition *is* the window being created.
