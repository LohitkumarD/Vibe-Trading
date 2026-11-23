# PropGuard backtests (v1.11, 21 Nov 2026)

Setup: EURUSD M15 chart, 1-minute OHLC, 2024-01-01 to 2026-11-20 (broker history starts 2024-01-09),
$100,000, 1:100, FundedNext 2-step preset (phase 1 target 8%), research mode on.

## The "B+D overtrading" bug

B was not overtrading next to D. B **on its own** was broken: after losing ~6.8% by June 2024 it sat
just above its own max-loss floor, every new trade was vetoed ("worst case would cross our floor"),
and it stayed idle for 2.5 years without ever counting as a failed challenge. In B+D the floor was
actually crossed, the challenge restarted, and trading continued, hence the much larger trade count.

Fix (RiskGuard.mqh, `GuardCanOpen`): in research mode, when the account is flat and even one trade
would breach the max-loss guard, count it as `FAILED (stalled ...)` and start a new challenge.
Tester only; live behaviour is unchanged. Also added `InpSmcTfPick` (1 M15, 2 M30, 3 H1, 4 H4) so the
optimiser can vary D's timeframe.

## Tuning D

18 combinations on 6 pairs (EURUSD, GBPUSD, USDJPY, AUDUSD, USDCAD, USDCHF): timeframe M15/M30/H1 x
displacement filter 0.4/0.6/0.8 ATR x min R:R 1.5/2.0. Tuned on 2024-01 to 2025-06, checked on
2025-07 to 2026-11 (unseen). M15 lost money in every combination. Chosen: **H1, 0.8 ATR, min R:R 1.5**
(profitable in both halves: PF 1.11 then 1.73). Full results: opt_D.xml / opt_D.forward.xml.

## Results

| Run | Passed / failed | Trades | Win rate | PF | Net | Max equity DD* |
|---|---|---|---|---|---|---|
| B fixed, 2 pairs | 0 / 4 | 633 | 32.4% | 0.85 | -$22,804 | 26.0% |
| A, 2 pairs | 0 / 0 | 355 | 46.2% | 1.05 | +$2,777 | 6.6% |
| D tuned, 6 pairs, 0.4% risk | 0 / 0 | 84 | 33.3% | 1.40 | +$4,507 | 2.9% |
| B + D tuned, 6 pairs | 3 / 10 | 1,462 | 33.7% | 0.87 | -$36,518 | 39.6% |
| A + D tuned, 6 pairs | 1 / 1 | 924 | 45.5% | 1.01 | +$1,346 | 9.8% |
| D tuned, 1% risk, 5-lot cap | 0 / 0 | 84 | 33.3% | 1.53 | +$6,705 | 2.9% |
| **D tuned, 1% risk, 20-lot cap** | **2 / 1** | 84 | 33.3% | 1.25 | +$10,181 | 11.6% |

*Drawdown is measured over the whole test, across restarted challenges.

At 1% risk the default 5-lot cap was binding (D's stops are tight), so risk was effectively much lower.
With a 20-lot cap the two passes took 202 and 323 days.

## Recommendation

- Drop B. It loses on its own and drags every combination down.
- D tuned is the only strategy with a consistent edge. At 1% risk with a 20-lot cap it passed 2 of 3
  challenges, but slowly (7 to 11 months) and on only 84 trades, which is a small sample.
- Do not buy a challenge on this alone. Next: forward-test D tuned on the FundedNext demo for 1 to 2
  months, and confirm the challenge has no time limit and allows 20-lot positions.

Settings for D tuned: InpUseA=false, InpUseB=false, InpUseD=true,
InpSymbols=EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,USDCHF, InpSmcTf=H1, InpSmcAtrFilter=0.8, InpSmcRR=1.5,
InpRiskPct=1.0, InpMaxLots=20.

These are now the EA's default inputs (v1.11). Earlier v1.10 results (B alone 0/0, D alone 17 trades)
were distorted by the stall bug above and the 2-pair, R:R 2.0 settings.
