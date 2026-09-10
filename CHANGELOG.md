# Changelog

Notable changes to DeepSeekBar. This project follows [Semantic Versioning](https://semver.org).

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
