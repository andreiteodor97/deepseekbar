# Changelog

Notable changes to DeepSeekBar. This project follows [Semantic Versioning](https://semver.org).

## [Unreleased]

### Fixed

- **The peak timeline was wrong for anyone outside UTC.** Peak windows were projected
  into local time but the hour labels beneath them were UTC, so the bars sat under the
  wrong numbers. The row that was meant to translate the windows into local time was
  skipped entirely, because it assumed the display was already UTC. The strip is now
  drawn and labelled in local time, with the UTC equivalent stated alongside.
- **"Today" could describe a different day than the rest of the panel.** The spend,
  tokens and cache-rate figures read the wall clock while the schedule and countdown read
  the store's own clock, so the two could disagree. Everything now follows one clock.
- **The savings line could read "$0.000 less".** Comparing today's cost against a
  fully-peak day is degenerate while peak is running — every token already was peak — so
  the line is now mode-aware: what off-peak has saved, or what peak is currently costing.
- Timeline bars clipped by the edge of the day are drawn square rather than rounded, so
  a window that continues past midnight no longer looks like it stops there. Windows that
  meet exactly are merged into one bar.

### Added

- A **"peak resumes"** line naming the weekday, local time and UTC time of the next peak
  window, with a countdown. Peak is 7 hours on 5 days out of 7, so "off-peak" is the
  normal state; without this the panel never explained when that changes.

## [2.0.0] — 2026-09-10

The first release worth using. A ground-up rewrite of the original status item.

### Added

- **Live peak/off-peak pricing** for DeepSeek's current rate card, with the schedule
  projected into your timezone, a timeline of the day, and a countdown to the next switch.
- **Real billed spend, token counts, cache-hit rate and lifetime cost**, read from the
  DeepSeek console. Signing in once in an embedded web view gets the app past the AWS WAF
  bot check that blocks plain HTTP clients, and the session persists.
- **Local spend estimate** from observed balance changes, used automatically when the
  console is not connected. Detects and excludes top-ups.
- **Notification when the rate flips**, so a long job can wait for half price.
- **A real vector whale mark**, traced from the official logo by `tools/trace_whale.py`. A
  downscaled bitmap turned to mush at 16pt.
- **Cache hit rate**, the single biggest cost lever: cached input is 50× cheaper.
- **Quantified off-peak savings**, computed from actual token counts and both rate cards.
- Settings for menu bar style, refresh interval, notifications, and launch at login.
- A test suite covering schedule boundaries, cost maths, and formatting.

### Fixed

- **Peak pricing was reported on Saturdays.** The original checked `weekday >= 2 && weekday <= 6`;
  in Foundation, `.weekday` is 1=Sunday…7=Saturday, so that range is Monday–Saturday. The app
  told you to expect double pricing on a day that bills at half, and missed the correct
  Friday cutoff.
- **The menu bar item could vanish** while the process kept running — macOS can evict a
  status item with no notification. It is now rebuilt on wake, on display changes, and on a
  slow heartbeat.
- **Keychain prompts on every launch.** Each ad-hoc rebuild produced a new code signature,
  so macOS treated every build as a new app and asked for the login password. Credentials
  now live in a `0600` file.
- The panel clipped its own footer, because `fittingSize` is meaningless before a layout pass.

### Changed

- Rates now match the official documentation: `deepseek-flash` at $0.003 / $0.15 / $0.60 per
  1M tokens off-peak, and exactly double at peak. `deepseek-v4-pro` bills at the Flash card
  as it is retired.
- Refresh is driven by the status item's own image rather than a text title, so the glyph,
  rate mode, and balance render together.
