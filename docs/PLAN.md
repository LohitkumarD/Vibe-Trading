# Prop-Firm Forex Bot: Master Plan

Status: draft v1 (2026-11-21). This is the plan the code will follow. Nothing here is financial or legal advice.

## 1. Goal

Build an automated forex trading system that can **pass and keep** funded (prop-firm) accounts. The priority order is:

1. **Never break a prop-firm rule.** Losing an account to a rule breach is worse than missing a profit.
2. Produce steady, modest returns (a 1–3% month is good on a funded account).
3. Be watchable and controllable from a phone, a tablet and a Windows laptop.

## 2. Key decisions (and why)

| Question | Decision | Why |
|---|---|---|
| Platform | **MetaTrader 5 (MT5)** | Offered by almost every prop firm. FTMO, The5ers and others allow EAs on MT5. FundedNext does **not** allow automated trading on cTrader or Match-Trader. |
| Language | **MQL5 Expert Advisor (EA)** | It runs inside the MT5 terminal with no external bridge. That keeps latency low, removes extra moving parts, and stays inside what firms accept. Python is used only offline for research. |
| Where it runs | **Windows VPS, 24/5**, located near the broker's servers (London or New York) | MT5 mobile apps **cannot run EAs** (Android/iOS run only manual trading). A laptop that sleeps, reboots or loses Wi-Fi would leave trades unmanaged. A VPS costs about $10–30 per month. |
| Phone / tablet / laptop | **Control and monitor only** (see section 4) | The bot lives on the VPS, and every device is a window into it. |
| Web-hosted service (e.g. a cloud MT5 API) | **Not in v1** | It adds monthly cost and a third party holding your login. Some firms ban external cloud copiers or bridges. We can revisit it for a web dashboard later. |
| Telegram bot | **Not inside the EA** | FundedNext explicitly bans EAs that connect to Telegram or WhatsApp. We use MT5's native push notifications instead, which every firm accepts. |

## 3. Architecture

```
            ┌──────────────────── Windows VPS (24/5) ────────────────────┐
            │  MT5 terminal (prop firm login)                            │
            │   └─ PropGuard EA                                          │
            │        ├─ RuleProfile   (firm limits: DD, reset time …)    │
            │        ├─ RiskGuard     (equity watch, kill switch)        │
            │        ├─ NewsFilter    (MT5 built-in economic calendar)   │
            │        ├─ Strategy A/B  (signals only, no sizing)          │
            │        ├─ Executor      (sizing, orders, SL/TP always set) │
            │        └─ Notifier      (MT5 push → phone/tablet)          │
            └────────────────────────────────────────────────────────────┘
     Phone / Tablet: MT5 app (positions, manual close), push alerts, RDP app
     Windows laptop: MT5 Strategy Tester (backtests), MetaEditor (code), RDP
```

Design rules:
- **Strategies never place orders directly.** They emit a signal (direction, entry, stop). The Executor sizes it, and RiskGuard can veto it.
- **Every order has a hard stop-loss on the server** at the moment it is sent. No "mental stops".
- **State survives restarts.** The day's start equity, peak equity, trade count and lockout flags are saved to a file and to terminal global variables, keyed by account login.

## 4. Running it from phone, tablet and laptop

| Need | How |
|---|---|
| See balance, equity, open trades | Official MT5 app (Android/iOS) logged into the same account (read-only investor password is enough) |
| Get alerts (trade opened/closed, daily limit near, EA paused, VPS restarted) | EA calls MT5 `SendNotification()` to your **MetaQuotes ID** (shown in the MT5 mobile app). Free, native and firm-safe. |
| Emergency stop | (a) Close positions in the MT5 app. The EA detects manual closes and pauses for the day. (b) Microsoft Remote Desktop / Windows App on phone, tablet or laptop → VPS → click "Pause" on the EA panel. |
| Change settings, update the EA | Laptop: edit in MetaEditor, test, then copy to the VPS over RDP. |
| Later (phase 5): web dashboard | A read-only status page fed from the EA's own log/heartbeat file, after checking the chosen firm's rules on external tools. |

## 5. Prop-firm risk engine (the core of the project)

### 5.1 How firms measure loss (researched)
- **Daily loss is measured on equity, continuously.** Floating P/L, swap and commission all count. Closing the day at -2.5% does not help if equity touched -5.1% at lunch.
- **The day resets at the firm's clock, not yours.** FTMO resets at midnight CET (Prague). FundedNext resets at midnight server time (GMT+2 / GMT+3 in summer). For Lohit in India that is around 03:30–04:30 IST. A position held across the reset carries its floating loss into the new day.
- **Max loss** is either **static** (for example, equity must stay above 90% of the starting balance) or **trailing** (it follows the balance high-water mark up and never down, often stopping at the starting balance).
- Typical numbers: 2-step challenges allow 5% daily and 10% max. 1-step challenges allow 3–4% daily and 6–8% max. **Always confirm on the firm's own help page for the exact account bought.**

### 5.2 RuleProfile (config per account)
`firm, account_size, daily_loss_pct, max_loss_pct, max_loss_type (static|trailing), daily_basis (start_balance|start_equity|max_of_both), reset_time + timezone, profit_target_pct, min_trading_days, news_rule (none|block_window|reduced_credit), news_window_min, weekend_holding (allowed|close_friday), max_lots, max_leverage, consistency_rule_pct, ea_allowed_on_size`

Shipped profiles in `profiles/`: FTMO 2-step, The5ers, FundedNext Stellar (2-step / 1-step / Lite). Every number is marked "verify before use".

### 5.3 RiskGuard behaviour
| Rule | Default |
|---|---|
| Internal daily stop | **60% of the firm's daily limit** (for example, stop at -3% on a 5% rule) |
| Internal max stop | **70% of the firm's max limit** |
| Risk per trade | **0.25–0.5% of starting balance** (never more than 1%) |
| Max open risk at once | 1.0% (sum of all open stop distances) |
| Max trades per day | 3 |
| After 2 losses in a day | Done for the day |
| Pre-reset rule | No new trades from 30 min before the firm's daily reset |
| News | No new entries 15 min before/after high-impact events for traded currencies (MT5 built-in calendar). Optionally tighten or close. |
| Weekend | Flat by Friday 20:00 server time unless the profile allows holding |
| Spread / slippage filter | Skip a trade if the spread is more than 2× normal |
| Target reached | When a challenge target is hit, drop to minimum risk and only take trades needed for minimum trading days |

The check runs **on every tick and on a 1-second timer**: worst-case equity (including the open trades' stop losses) against the internal stops. On breach: close everything, cancel pending orders, lock until the next reset, and push an alert.

### 5.4 Banned techniques (the bot will never use these)
Martingale, grid, averaging down, hedging across accounts, HFT, tick scalping, latency arbitrage, copy trading between a funded account and another account, and "challenge-passing" bots. These breach most firms' terms and also blow accounts.

## 6. Strategies

Requirements for any strategy: a stop on every trade, a holding time of minutes to days (not seconds), clear and testable rules, and it must work with 0.25–0.5% risk.

| # | Strategy | Market / time | Idea |
|---|---|---|---|
| A | **London session breakout** | EURUSD, GBPUSD; M15; London open | Mark the Asian-session range. Trade a confirmed break with the stop on the other side of the range or an ATR-based stop, 1.5–2R target, one trade per pair per day. |
| B | **Trend pullback** | EURUSD, GBPUSD, USDJPY, XAUUSD (if allowed); H1 with H4 filter | Trade in the direction of the H4 trend (EMA 50/200). Enter on a pullback to the H1 EMA 20/50 with a momentum confirmation. ATR stop, partial close at 1R, trail the rest. |
| C | **Range mean-reversion** (later) | EURCHF, AUDNZD; Asian session | Fade Bollinger/RSI extremes only when a volatility filter says the market is ranging. Tight time stop. |

We start with **A and B**. Strategies with low correlation smooth daily equity, which matters more for prop rules than raw return.

### 6.1 How a strategy earns its place
1. **Backtest** in the MT5 Strategy Tester with "Every tick based on real ticks", realistic commission and variable spread, over at least 5 years.
2. **Walk-forward**: optimise on one period, then test on the next unseen period. Keep only settings that are stable across neighbours (no single "magic" values).
3. **Prop simulation**: replay the trades through the RuleProfile. Use Monte Carlo (shuffle trade order, 5,000 runs) to estimate the **probability of breaching the daily or max limit** and of reaching the target within 30/60 days.
4. **Acceptance bar**: profit factor above 1.3, breach probability under 5%, worst day under 50% of the daily limit, at least 200 trades in the test.
5. **Forward test** on a demo account for at least 4 weeks on the VPS, then on a free trial or the cheapest challenge.

## 7. Repository layout (target)

```
mql5/
  Experts/PropGuardEA.mq5
  Include/PropGuard/
    RuleProfile.mqh  RiskGuard.mqh  NewsFilter.mqh
    Executor.mqh     Notifier.mqh   StateStore.mqh
    Strategies/LondonBreakout.mqh  Strategies/TrendPullback.mqh
profiles/            # one .set/.json per firm/account type
research/            # Python: trade-log analysis, Monte Carlo, prop simulation
docs/                # this plan, VPS setup guide, runbook
```

## 8. Roadmap

| Phase | Deliverable | Done when |
|---|---|---|
| 0 | Repo reset + this plan | PR merged |
| 1 | **RiskGuard + RuleProfile + StateStore + Notifier** with a dummy strategy | Strategy Tester shows it flattening and locking at the internal limits, with the correct reset time per firm |
| 2 | Strategy A (London breakout) + backtest report | Passes the 6.1 bar or is dropped |
| 3 | Strategy B (trend pullback) + combined portfolio test | Monte Carlo breach probability under 5% |
| 4 | VPS setup guide + 4-week demo forward test | Live demo results match the backtest within reason |
| 5 | Challenge attempt, and optionally a read-only web dashboard | Challenge passed without coming near a limit |

## 9. Important: India-specific legal note

Lohit is based in India. The **RBI "Alert List"** names forex platforms that are not authorised for Indian residents under FEMA 1999. In October 2024 it added the first prop firms, **FundedNext** and **Smart Prop Trader**. Paying fees to listed entities or trading on them can breach FEMA. Before buying any challenge:
- Check the current RBI Alert List: https://www.rbi.org.in (search "Alert List").
- Talk to a chartered accountant about how fees and payouts are treated (LRS, tax).

The software is firm-agnostic. Choosing a firm is a separate decision.

## 10. Open items for Lohit (not blocking phase 1)
- Which firm and account size to target first. My default is the FTMO 2-step profile, because FTMO allows EAs on all account sizes, but see section 9.
- VPS budget (about $10–30 per month), to be bought when phase 4 starts.
- Your MetaQuotes ID (from the MT5 mobile app → Settings → Messages) for push alerts.

## Sources
- FundedNext EA rules (Oct 2026): https://www.mql5.com/en/blogs/post/776725
- General prop-firm EA rules: https://audacity.capital/de/trading-guides/best-prop-firms-allow-ea/
- How daily loss is really calculated: https://www.mql5.com/en/blogs/post/775438
- MT5 mobile does not run EAs: https://www.mql5.com/en/blogs/post/777309
- Static vs trailing max drawdown (OANDA prop): https://proptrader-help.oanda.com/what-is-maximum-drawdown-and-how-is-it-calculated
- RBI alert list adds prop firms (Oct 2024): https://www.financemagnates.com/forex/two-prop-firms-and-thinkmarkets-added-to-indias-central-bank-warning-list/
