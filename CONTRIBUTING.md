# Contributing to DeepSeekBar

Thanks for taking a look. This is a small, dependency-free codebase, and the goal is to
keep it that way.

## Getting set up

```sh
git clone https://github.com/andreiteodor97/deepseekbar.git
cd deepseekbar
make test     # should pass on a clean checkout
make run      # compile, install to ~/Applications, and launch
```

You need macOS 13+ and the Xcode command line tools. There is no Xcode project, no Swift
Package manifest, and no third-party dependency — `build.sh` calls `swiftc` directly. If a
change needs a dependency, it needs a conversation first.

Logs go to `/tmp/dsbar.log`. There is no debugger-friendly way to inspect a menu bar app,
so that file is the primary diagnostic: status item renders, panel sizing, and rebuilds
are all recorded there.

## Before you open a pull request

```sh
make check    # runs the test suite
./build.sh    # must compile with zero warnings
```

A new compiler warning is a regression. The build is currently clean and should stay that
way.

## Testing

`./test.sh` runs the suite in `tools/tests/main.swift`. It covers the parts most likely to
be subtly wrong:

- **Schedule boundaries** — every edge of 01:00, 04:00, 06:00 and 10:00 UTC, plus the
  Friday→Saturday and Sunday→Monday transitions. Getting the weekday wrong means the app
  reports peak pricing on a weekend, which is exactly the class of bug this project exists
  to prevent.
- **Transitions** — that the countdown targets the right instant, including the 61-hour
  off-peak run from Friday 12:00 UTC to Monday 01:00 UTC.
- **Cost maths** — that peak is exactly 2× off-peak across a mixed token basket.
- **Formatters** — money, token counts, countdowns, and timezone projection.

If you touch `Pricing.swift`, add a case. If you touch anything that renders, at minimum
verify the app builds, launches, and still shows its menu bar item.

## Architecture notes

A few decisions that are load-bearing and worth understanding before changing:

**Credentials are a file, not the keychain.** Ad-hoc signed builds get a new signature on
every rebuild, so the keychain prompts for a password each launch. Don't move this back.

**Console requests run inside a `WKWebView`.** The console API is behind an AWS WAF
challenge that a plain `URLSession` cannot pass. Requests are issued from inside the loaded
page so the bot-check cookie is applied and refreshed. `URLSession` will get `202` with an
empty body.

**The status item is rebuilt on wake, screen changes, and a slow heartbeat.** macOS can
evict a status item with no notification: `isVisible` stays `true` and the item does not
appear in the window-server window list. Rebuilding is cheap and invisible, so the app
does it defensively rather than trying to detect the eviction.

**The whale glyph is generated.** `Sources/WhaleGlyph.swift` is written by
`tools/trace_whale.py` from `tools/deepseek-logo.png`. Edit the tracer, not the generated
file; `build.sh` regenerates it when the tracer changes.

**Peak pricing is UTC.** DeepSeek bills "working days" against UTC, and both the schedule
and the console's day boundaries follow it. The UI projects windows into the viewer's
timezone for display but never for calculation.

## Reporting bugs

Please include:

- macOS version and whether you built from source or downloaded a release
- Whether the menu bar item is present, and whether the panel opens
- The last ~30 lines of `/tmp/dsbar.log`
- For a pricing question: your timezone and the current UTC time

If the menu bar item disappeared, that is the highest-priority class of bug. Say so
explicitly.

## Pricing changes

If DeepSeek changes its rate card or schedule, update `Rate` and `Schedule.peakWindows` in
`Sources/Pricing.swift`, update the tests in `tools/tests/main.swift`, and cite the page
you got the numbers from in the pull request.

## Style

Match the surrounding code. Comments explain *why*, not *what* — the code already says
what it does. Prefer clarity over cleverness, and keep the dependency count at zero.
