# Launch post — DeepSeekBar 2.0

Two ready-to-post versions: a thread for X, and a single post if you would rather not
thread. Both are under X's 280-character limit per post.

Repo: https://github.com/andreiteodor97/deepseekbar

---

## Thread version (recommended)

**1/**

> DeepSeek API pricing doubles during peak hours.
>
> Nothing in the API tells you which rate you're on.
>
> So I built a menu bar app that does: 🐳 $5.04 cheap
>
> It reads your real spend straight from the console. Open source, no dependencies.
>
> github.com/andreiteodor97/deepseekbar

**2/**

> The pricing model is the whole idea:
>
> • Off-peak: $0.003 / $0.15 / $0.60 per 1M tokens
> • Peak: exactly 2× that
> • Peak = 01:00–04:00 and 06:00–10:00 UTC, Mon–Fri
>
> Schedule a long job 20 minutes later and it costs half as much. The app counts down to the switch.

**3/**

> It also shows the number that actually moves your bill:
>
> Cached input costs $0.003/M. Uncached costs $0.15/M.
>
> That's 50×.
>
> So the panel puts your cache hit rate right next to your spend. Mine is 99.6%.

**4/**

> Connecting your account gets you DeepSeek's own numbers — cost per day, request counts, full token split, lifetime spend.
>
> That meant reverse-engineering the console API, which sits behind an AWS WAF check that returns 202 to anything that isn't a browser.
>
> The app solves it in a web view. Once.

**5/**

> Three bugs found along the way, all in my own first attempt:
>
> 1. It reported peak pricing on Saturdays (Foundation weekdays are 1=Sun, not 1=Mon)
> 2. The whale logo turned to mush at 16pt — rasterising it was the wrong call
> 3. macOS silently evicts menu bar items. The app vanished while still running.

**6/**

> The whale is now a real traced vector, not a bitmap.
>
> Zero dependencies. No Xcode project. Just swiftc and ten files.
>
> brew install --cask https://github.com/andreiteodor97/deepseekbar/raw/main/Casks/DeepSeekBar.rb
>
> MIT. PRs welcome, especially if DeepSeek changes its rate card.

---

## Single post version

> DeepSeek's API costs 2× during peak hours, and nothing tells you which rate you're on.
>
> So I built a menu bar app: 🐳 $5.04 cheap
>
> Live rates, a countdown to the next price switch, cache-hit rate, and your real spend from the console.
>
> Free, MIT, zero dependencies.
> github.com/andreiteodor97/deepseekbar

---

## If you want one more post after launch

**7/ (optional follow-up)**

> Numbers from building this, for anyone who cares about the details:
>
> • 10 Swift files, no dependencies, ~5k lines
> • Compiles in 57s, ships as a 2.4MB dmg
> • The 30-test suite is almost entirely about the peak schedule
>
> The boring parts are where the bugs live.

---

## Images

All of these are checked into the repo and regenerate with `make screenshots`:

| File | Use |
|---|---|
| `docs/panel.png` | **Attach to post 1.** Balance, live rate, peak timeline, countdown. |
| `docs/panel-usage.png` | Attach to post 4 (real spend, token split, cache hit rate). |
| `docs/menu-bar.png` | The menu bar strip, if you want a wide banner image. |

A short screen recording of the panel opening, with the countdown ticking, will outperform
a still if you have a minute to grab one — the timeline moving is the part that lands.

## Notes before posting

- The repository is live at github.com/andreiteodor97/deepseekbar, with a v2.0.0 release,
  working Homebrew cask, and green CI. All links in the posts below resolve.
- Post 1 is the only one that needs to stand alone — most people will never expand the thread.
- If you want to tag DeepSeek, do it in a reply rather than the first post; it reads as less
  of a growth play and more of a genuine build log.
- If someone asks "why not just use the API", the answer is in post 4: the API gives you a
  balance, not a cost history, and the console that does have it is behind a bot check.
