# BetterWheel

Rust TUI assistant for running the options **wheel strategy** on Interactive
Brokers. Connects to IB Gateway/TWS via the `ibapi` crate; persists local state
in SQLite. Paper-first and safety-gated.

## Commands

```bash
cargo build
cargo test                       # unit tests live next to the code (#[cfg(test)])
cargo clippy --all-targets
cargo run                        # launch the TUI (reads ./config.toml)
cargo run --bin spike -- AAPL    # read-only Gateway connectivity probe (default AAPL)

# Desktop app (Tauri) — an additional front-end; the TUI is unchanged.
npm install                      # one-time: fetch the Tauri CLI
npm run dev                      # launch the desktop dashboard (reads ./config.toml)
scripts/release.sh "notes…"      # build + minisign + publish a desktop release (updater feed)
```

Edition 2024; no pinned toolchain. Tests are pure and need no Gateway/network
(`engine`, `positions`, and parts of `tui::app`); `Store::open_in_memory()`
backs store tests.

## Architecture (layers, strictly separated)

- `engine/` — **pure strategy logic, zero I/O.** Selectors `csp` (entry),
  `covered_call` (post-assignment income), `manage` (take-profit / roll), a
  Black-Scholes delta fallback in `math` (used when IBKR reports no greek), and
  plain `types`. `plan()` ranks suggestions: management (close, roll) before new
  entries, then by annualized yield. Fully unit-testable; keep it broker-agnostic.
- `engine/structures/` — **a second strategy family: 0DTE/short-dated *index*
  structures** (iron condor, put/call credit spread, broken-wing fly, iron fly,
  gated short strangle). Pure selectors over a both-sides chain; a generic
  piecewise-linear payoff engine (`payoff_at`/`max_loss_per_share`/`breakevens`)
  derives risk/reward for any leg set. These ride on
  `ActionKind::OpenStructure { kind, legs }` and are **not** part of the wheel's
  `WheelState` machine (SPX is cash-settled/European — no assignment/shares,
  intraday, multi-leg). Surfaced on the **0DTE tab** (a 2×2 grid of roster slots).
- `ibkr/` — **the SOLE `ibapi` boundary.** Owns the `ibapi::Client` and maps
  `ibapi` types into plain structs (`PositionRow`, `ChainMeta`, `SnapshotData`,
  `OrderEvent`, `OpenOrderInfo`, `PortfolioRow`, …). Do not import `ibapi`
  anywhere else. Every streaming request is bounded by a timeout. There is one
  `submit_or_preview*` entry per order shape so preview and live paths can't
  diverge (`preview=true` → what-if `analyze()`; `false` → `submit()`):
  `submit_or_preview` (single option), `_spread`/`_combo` (BAG), and
  `submit_or_preview_equity` (manual stock/ETF — Limit/MidPrice/protected-Market/
  Adaptive via `EquityOrderKind`). `marketable_limit()` is a pure helper that
  crosses the live book to a capped price (returns `None` on an unusable quote —
  never a silent market order). `account_portfolio()` (mark + unrealized P&L) and
  the widened `open_orders_snapshot()` feed the Portfolio/Orders views.
- `positions.rs` — **pure broker→wheel-state reconciliation.** Flattened
  holdings → `WheelState` + share lot + open short. No I/O; exhaustively tested
  (it's the safety net for the connection-only path).
- `store/` — SQLite persistence via `sqlx` (tables: `watchlist`,
  `wheel_positions`, `journal`, `settings`, `pending_rolls`, `zerodte_positions`
  (auto-managed structures), `zerodte_settings` (in-app slot overrides); see
  `migrations/`). Migrations run automatically on `Store::open`. Holds the wheel
  metadata IBKR can't report (which leg, cost basis, cumulative premium).
- `data.rs` — **the UI-agnostic live-data layer** (free functions, no UI state).
  Turns IBKR market data + holdings into ranked `Suggestion`s, syncs broker
  positions into the store, probes tradability, resolves roll targets. `gather()`
  is the one connected-reload pipeline any front-end drives.
- `tui/` — `ratatui` app. `app.rs` = state + key→`Action` dispatch (async work),
  `ui.rs` = **pure render function of `App`**, `mod.rs` = `tokio::select!` run
  loop (key events + broker order-event stream + redraw + a 30s 0DTE scheduler
  tick), `schedule.rs` = **pure** US/Eastern market-time + entry-timing helpers.
  Beyond the strategy tabs there's a manual-trading surface: a **Trade** tab (an
  equity/ETF order ticket — `TradeForm`, j/k field focus + h/l adjust, priced via
  `marketable_limit`/MidPrice/Adaptive and run through the *same* preview→arm→
  execute gate as suggestions), an **Orders** tab (live working orders, `d`/`c`
  cancels the selected one), and a **Portfolio** tab (live positions + unrealized
  P&L). Equity orders journal as `action = "equity BUY/SELL"`.
- `config.rs` — TOML config (connection, engine tuning, guardrails); every field
  defaults, so a missing `config.toml` still runs. See `config.toml.example`.
- `src-tauri/` + `dist/` — the **desktop app** (a separate `betterwheel-desktop`
  crate that path-deps the lib). `src-tauri/src/lib.rs` runs a background task that
  drives `data::gather` (or demo) and emits a cached snapshot; `dist/` is a
  build-free static frontend (vanilla JS over `window.__TAURI__`, inline-SVG payoff
  charts). The desktop **drives the same `App`** and transmits through its `ui_*`
  facade (suggestions *and* the manual Trade ticket / Orders cancel) — so the
  guardrail/arm/execute code is never reimplemented webview-side. See the desktop
  section below.

Data flow when connected: `ibkr.positions()` → `positions::reconcile` → sync into
`store` → `engine::plan` over live chains → suggestions.

## Safety model (do not weaken)

- **Paper-first.** `connection.mode = "paper"` by default (port 4002).
- **Transmit is a 3-step gate:** preview/what-if (`p`) → **arm** (`A` toggles
  `armed`) → execute (`x`). A successful live submit **auto-disarms**.
- **Guardrails** (config, enforced in `app::execute_suggestion` /
  `execute_equity_order` regardless of engine output): `read_only` blocks all
  transmits; `max_contracts_per_order` caps option order size; `max_total_deployed`
  caps total CSP collateral (split across the active watchlist when sizing);
  `max_order_notional` caps a single manual equity ticket (price × shares — a live
  equity order is refused until a quote is fetched so it's never sized blind).
- `ibkr.positions()` returns `Err` on an **incomplete** snapshot (stream error /
  timeout before `PositionEnd`). Callers must treat that as "unknown", never as
  "account is empty" — a failed fetch must not wipe wheel state or surface stale
  executable suggestions. Preserve this distinction in any refactor.
- **0DTE auto-management is opt-in per slot.** The scheduler (`app::tick_zerodte`,
  a run-loop tick) transmits *only* for a slot whose `automate` flag is on (toggled
  in-app with `t` on the 0DTE tab, persisted to `zerodte_settings`), and still
  honors `read_only` + `max_contracts_per_order`. It enters at the configured time
  and places a **standing profit-close** on fill; "the wings are the stop" (no
  separate stop order for defined-risk structures). A loud "⚡ AUTO-TRADING" header
  banner shows whenever a slot is live. **Default off** — do not weaken this gate.

## Desktop app (Tauri) & auto-update

The `betterwheel-desktop` crate (`src-tauri/`) is a native dashboard, modeled on the
sibling `marie-lookapp`. Build-free static frontend (`dist/`, vanilla JS over
`window.__TAURI__`, `withGlobalTauri`); strict CSP; payoff curves are inline SVG
(no chart lib). The lib stays clean — all Tauri/webview deps live in `src-tauri/`.

- **Transmit via the `App` facade** (no separate "Session" core was needed): a
  background task connects to Gateway (or falls back to demo data offline), runs
  `data::gather`, caches a `Snapshot`, and emits it to the webview. Orders go
  through `App`'s `ui_*` facade — `ui_preview`/`ui_execute` (suggestions, by
  list+index), `ui_set_trade` + `ui_trade_preview`/`ui_trade_execute` (the manual
  equity ticket), and `ui_cancel_order` — so the preview→arm→execute→live-confirm
  guardrail code runs **once**, in `tui::app::App`, shared by both front-ends. The
  webview only collects form fields; it reimplements no order logic.
- **Auto-update** = `tauri-plugin-updater` (minisign, `native-tls` to dodge the
  cargo-xwin/`ring` cross-compile break). It checks `latest.json` on the
  **`betterwheel/betterwheel.github.io`** repo's GitHub Releases. The updater fetches
  anonymously, so **that repo MUST be public** for auto-update to work — releases on a
  private repo can't be downloaded without auth (it's public, so auto-update works).
  That repo is the separate **landing site** (served from its root `index.html`) *and*
  the release host; **this** `betterwheel` repo holds only the app code (TUI + desktop).
  `dist/update.js` drives check → download → `process.relaunch()`.
  macOS isn't notarized (right-click→Open first run) and uses no TCC permission, so
  the default ad-hoc signature is fine — the updater only verifies the **minisign**
  signature.
- **Releasing** (local, no CI): bump the version in `tauri.conf.json` +
  `package.json` + `src-tauri/Cargo.toml`, then `scripts/release.sh "notes…"`
  (cross-compiles Windows via cargo-xwin → NSIS installer, builds the macOS
  bundle, minisigns the artifacts, writes `latest.json`, `gh release create` on the
  releases repo). Do **not** mark the release `--prerelease` (the `releases/latest`
  endpoint skips prereleases, hiding them from the updater). Authenticode is opt-in
  (`SKIP_AUTHENTICODE=0` + the `betterwheel-signing` keychain item).
- **Updater key:** `~/.tauri/betterwheel-updater.key` (passwordless; pubkey embedded
  in `tauri.conf.json`). Never commit it; losing it bricks auto-update for installed
  apps — back it up.

## Conventions & gotchas

- **Logging is file-only** (`<data_dir>/logs/betterwheel.log`). Never log to stdout/
  stderr from the TUI path — it corrupts ratatui's alternate screen. (The `spike`
  binary logs to stderr because it has no TUI.)
- **Money is `f64`** throughout (prices, premium, collateral). No decimal type.
- **Offline fallback:** if Gateway isn't reachable within 5s at startup, the TUI
  runs with Black-Scholes-consistent demo data (`tui/demo.rs`) so it's always
  usable. `App.connected` / `ibkr: Option` gate all live paths.
- **Greeks may be missing** (paper accounts, illiquid strikes): the engine falls
  back to `math::bs_delta` from implied volatility to filter by moneyness.
- **Live market data needs IBKR web-portal setup first.** Even connected on
  paper, the API returns no option prices/greeks — codes `10091`/`10167`, so the
  Suggestions tab stays empty — until you complete, in the IBKR web portal
  (Client Portal): the **"Market Data API access configuration"**, the
  **"Non-Commercial Form"**, and your **Market Data Subscriber Status**, *and*
  hold the actual subscription (OPRA for US options). The app connects fine
  without these; it just can't rank anything. Offline/demo mode is unaffected.
- IBKR right strings vary (`P`/`PUT`/`C`/`CALL`); option `average_cost` includes
  the contract multiplier, so per-share credit = `average_cost / multiplier`
  (see `positions.rs`). Expiries are `YYYYMMDD`; contract-month-only expiries are
  dropped (can't be dated).
- **Index options (SPX / 0DTE) differ from stocks**, all handled in `ibkr/`:
  resolve the underlying as `SecurityType::Index` (`underlying_contract`);
  `option_chain` **unions all trading classes** so the SPXW dailies (where 0DTE
  lives) come in — taking only the first stream entry misses every same-day
  expiry; and index order prices tick in **$0.05**, not $0.01 — an off-tick combo
  limit gets IBKR error 110 and the request *hangs* (`round_to_tick`/`order_tick`).
  Multi-leg structures submit as one **guaranteed** combo (BAG) via
  `submit_or_preview_combo`; the profit-close is the entry combo with every leg
  flipped, bought at the target debit.
- Secrets are gitignored: `config.toml` and `*.pem` are never committed.
- `docs/legacy-webapi/` is **archived** (an abandoned Web API/OAuth broker layer);
  the live broker layer is TWS-via-`ibapi`. Don't treat it as current code.
