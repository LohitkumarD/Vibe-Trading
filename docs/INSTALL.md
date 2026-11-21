# Install PropGuard EA on your laptop (MT5 demo / free trial)

Version 1.00: risk engine + Strategy A (London breakout). **Use a demo or free-trial account only** until it has passed the 4-week forward test in PLAN.md.

## 1. Copy the files into MT5

1. In MT5: **File → Open Data Folder**. A Windows folder opens. Go into **MQL5**.
2. From this repo, copy:
   - `mql5/Include/PropGuard/` (the whole folder) → into `MQL5\Include\`
   - `mql5/Experts/PropGuard/` (the whole folder) → into `MQL5\Experts\`

   You should end up with `MQL5\Include\PropGuard\RiskGuard.mqh` and `MQL5\Experts\PropGuard\PropGuardEA.mq5`.
   (To download: on GitHub open the branch → green **Code** button → **Download ZIP**, then unzip.)

## 2. Compile

1. In MT5 press **F4** (opens MetaEditor).
2. In the Navigator on the left: **Experts → PropGuard → PropGuardEA.mq5**, double-click it.
3. Press **F7** (Compile). The bottom "Errors" tab should say `0 errors`.
   **If there are errors, copy the whole Errors tab text and send it to Claude.** The code was written without access to the MT5 compiler, so a small fix may be needed.

## 3. Turn on what the EA needs (once)

**Tools → Options → Expert Advisors**:
- ✅ Allow algorithmic trading
- ❌ "Disable algorithmic trading when the account has been changed" (optional, keep on if you switch accounts often)

**Tools → Options → Notifications** (for phone alerts):
- ✅ Enable Push Notifications
- MetaQuotes ID: open the **MT5 app on your phone → Settings → Messages**, copy the MetaQuotes ID, paste it here, and click **Test**.

On the toolbar, the **Algo Trading** button must be green.

## 4. Attach it to a chart

1. Open **one** chart, e.g. EURUSD M15 (any symbol/timeframe works; the EA trades every symbol in its list).
2. Drag **PropGuardEA** from Navigator → Expert Advisors onto the chart.
3. **Common** tab: ✅ Allow Algo Trading.
4. **Inputs** tab, check at least:

| Input | What to set |
|---|---|
| Firm / challenge preset | Default **FundedNext Stellar 2-Step** (5% daily / 10% max, resets at server midnight). Pick 1-Step if your trial is 1-Step |
| Account starting balance | The account size, e.g. `100000` for a 100K trial. `0` = current balance |
| Symbols | Exact names from Market Watch. Some brokers add a suffix, e.g. `EURUSD.r` |
| Risk per trade | Default 0.40%. Keep it at or below 0.5% |
| Asian range / London hours | Defaults are for GMT+2/+3 servers (FTMO and most prop firms). Check the server time in Market Watch: London opens at 10:00 on these servers |

5. Click **OK**. A smiling hat appears in the chart's top-right corner, with the status text top-left and two buttons:
   - **PAUSE / RESUME**: stops new trades. Open trades keep their stop-loss and take-profit.
   - **CLOSE ALL + PAUSE**: emergency exit.

## 5. Laptop settings so it keeps running
- **Settings → System → Power**: when plugged in, screen off is fine but **Sleep = Never**. Lid close action: **Do nothing**.
- **Windows Update → Advanced → Active hours**: 10:00–23:59. Pause updates during a challenge.
- Optional: put an MT5 shortcut in `shell:startup` so it opens after a restart. The EA restores its state from `MQL5\Files\PropGuard_<login>.txt`.

## 6. What it does (v1.00)
- Watches equity every second. Stops for the day at **60% of the firm's daily loss limit** and locks the account at **70% of the max loss limit**. On a breach it closes everything.
- Refuses a new trade if equity minus all open stop-losses minus the new trade's risk would cross that line.
- Max 3 trades and 2 losses per day. No entries in the 30 minutes before the firm's daily reset, or 15 minutes around high-impact news.
- Flat on Friday from 21:00 server time.
- If you close a trade by hand (phone, PC or web), it pauses until the next daily reset.
- Sends push alerts to your phone for entries, exits, pauses and breaches.

## 7. Weekend backtest (Strategy Tester)

The market is closed at the weekend, but the tester works on downloaded history, so this is the right time to run it.

1. **View → Strategy Tester** (Ctrl+R). On the **Settings** tab:

| Field | Value |
|---|---|
| Expert | `PropGuard\PropGuardEA.ex5` |
| Symbol | EURUSD (the chart symbol only; the EA trades every symbol in its *Symbols* input) |
| Timeframe | M15 |
| Date | Custom period: **2024.01.01 → 2026.11.20** |
| Forward | No |
| Delays | Random delay |
| Modelling | **Every tick based on real ticks**. If it's very slow or says real ticks are missing, use **1 minute OHLC** |
| Deposit / Leverage | 100000 USD, 1:100 |
| Optimization | Disabled |
| Visual mode | Off |

2. **Inputs** tab: set *Account starting balance* = `100000`, keep *Firm* = FundedNext Stellar 2-Step, *Server GMT offset in winter* = `2`, *Server shifts with US DST* = `true`. Leave everything else at the defaults.
3. Click **Start**. The first run downloads history, which can take 10–30 minutes.
4. Run it **three times**, changing only *Symbols*: `EURUSD`, then `GBPUSD`, then `EURUSD,GBPUSD`.
5. For each run, send Claude:
   - a screenshot of the **Backtest** tab (the numbers) and the **Graph** tab,
   - or right-click the Backtest tab → **Report → HTML** and upload the file,
   - plus any **Journal** lines containing `FLATTENED` or `daily guard`.

What Claude will check: profit factor, max drawdown, the worst single day versus the 5% daily rule, number of trades, and whether the guard ever had to step in.

The news filter is off in the tester, because MT5's calendar isn't available there.
