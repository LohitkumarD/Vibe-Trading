#ifndef PG_SMCSTRUCTURE
#define PG_SMCSTRUCTURE
//+------------------------------------------------------------------+
//| SmcStructure.mqh - Strategy D (port of Lohit's                   |
//| structure-smc-backtest: structure.ts, zones.ts, indicators.ts)   |
//|                                                                  |
//| On every closed bar of the chosen timeframe:                     |
//|  1. Fractal swings (strict, N bars each side), released only     |
//|     once N bars have closed after them (no look-ahead).          |
//|  2. BOS / CHoCH on candle CLOSE (or wick) through the last swing.|
//|  3. Displacement filter: break candle body >= atrFilter x ATR.   |
//|  4. Entry zone: Order Block (last opposite candle) or FVG.       |
//|  5. Limit order at the zone's proximal edge, valid for           |
//|     maxRetraceBars bars ("retrace" mode).                        |
//|  6. Stop = the swept structural swing (+ ATR buffer).            |
//|     Target = nearest liquidity pool (swing), else rr x risk.     |
//|     Skip if target/risk < minimum R:R.                           |
//|  7. Time stop after maxBars bars.                                |
//+------------------------------------------------------------------+
#include "../Executor.mqh"

struct SmcConfig
  {
   ENUM_TIMEFRAMES   tf;
   int               swingLen;
   bool              closeConfirm;      // true = close through level, false = wick
   int               signalType;        // 0 both, 1 BOS only, 2 CHoCH only
   double            atrFilter;
   int               atrPeriod;
   bool              useOB;             // true = Order Block, false = FVG
   bool              wickBounds;        // OB bounds: true wick, false body
   double            fvgMinAtr;
   int               maxRetraceBars;
   double            stopBufferAtr;
   double            rr;                // fallback target and minimum R:R
   int               maxBars;           // time stop
   int               startHour;         // server time window for new signals
   int               endHour;
  };

struct SmcSymState
  {
   string            sym;
   datetime          lastBar;
  };

SmcConfig   g_smc;
SmcSymState g_smcs[];

bool SmcInit(const SmcConfig &cfg, string &symbols[])
  {
   g_smc = cfg;
   ArrayResize(g_smcs, ArraySize(symbols));
   for(int i = 0; i < ArraySize(symbols); i++)
     {
      g_smcs[i].sym = symbols[i];
      g_smcs[i].lastBar = 0;
     }
   return true;
  }

//--- Wilder ATR as in indicators.ts (atr[i] as of bar i)
void SmcAtr(const MqlRates &r[], int n, int period, double &atr[])
  {
   ArrayResize(atr, n);
   if(n == 0)
      return;
   int p = MathMax(1, period);
   double sum = 0.0;
   for(int i = 0; i < n; i++)
     {
      double tr = (i == 0) ? r[0].high - r[0].low
                  : MathMax(r[i].high - r[i].low,
                    MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      if(i < p)
        { sum += tr; atr[i] = sum / (i + 1); }
      else if(i == p)
         atr[i] = ((sum / p) * (p - 1) + tr) / p;
      else
         atr[i] = (atr[i - 1] * (p - 1) + tr) / p;
     }
  }

//--- Strict fractal swings. kind[i]: 0 none, 1 high, 2 low, 3 both
void SmcSwings(const MqlRates &r[], int n, int N, int &kind[])
  {
   ArrayResize(kind, n);
   ArrayInitialize(kind, 0);
   for(int i = N; i < n - N; i++)
     {
      bool isHigh = true, isLow = true;
      for(int j = i - N; j <= i + N; j++)
        {
         if(j == i)
            continue;
         if(r[j].high >= r[i].high) isHigh = false;
         if(r[j].low <= r[i].low)   isLow = false;
         if(!isHigh && !isLow)
            break;
        }
      kind[i] = (isHigh ? 1 : 0) + (isLow ? 2 : 0);
     }
  }

//--- Run the structure scan; report the event on the LAST bar, if any.
//--- dir: +1 bull / -1 bear, isChoch, stopLevel (swept swing), ok if found
bool SmcLastEvent(const MqlRates &r[], int n, int N, bool closeConfirm, const int &kind[],
                  int &dir, bool &isChoch, double &stopLevel)
  {
   double upper = 0, lower = 0, lastHigh = 0, lastLow = 0;
   bool hasUpper = false, hasLower = false, hasLastHigh = false, hasLastLow = false;
   int trend = 0;   // +1 up, -1 down, 0 none
   for(int i = 0; i < n; i++)
     {
      int s = i - N;   // swing confirmed exactly at this bar
      if(s >= 0 && kind[s] != 0)
        {
         if((kind[s] & 1) != 0) { upper = r[s].high; hasUpper = true; lastHigh = upper; hasLastHigh = true; }
         if((kind[s] & 2) != 0) { lower = r[s].low;  hasLower = true; lastLow = lower;  hasLastLow = true; }
        }
      bool bull = hasUpper && (closeConfirm ? r[i].close > upper : r[i].high > upper);
      bool bear = hasLower && (closeConfirm ? r[i].close < lower : r[i].low < lower);
      int d = 0;
      if(bull && bear) d = (r[i].close >= r[i].open) ? 1 : -1;
      else if(bull)    d = 1;
      else if(bear)    d = -1;
      if(d == 0)
         continue;
      if(d > 0)
        {
         if(i == n - 1)
           {
            dir = 1; isChoch = (trend == -1);
            if(!hasLastLow) return false;
            stopLevel = lastLow;
            return true;
           }
         trend = 1; hasUpper = false;
        }
      else
        {
         if(i == n - 1)
           {
            dir = -1; isChoch = (trend == 1);
            if(!hasLastHigh) return false;
            stopLevel = lastHigh;
            return true;
           }
         trend = -1; hasLower = false;
        }
     }
   return false;
  }

bool SmcCheck(int idx, long magic, TradeSignal &s)
  {
   ClearSignal(s);
   string sym = g_smcs[idx].sym;
   int barSec = PeriodSeconds(g_smc.tf);

   // Housekeeping: unfilled limits expire, old trades time out
   ExpireOwnOrders(sym, magic, "SMC", g_smc.maxRetraceBars * barSec);
   TimeStopOwn(sym, magic, "SMC", g_smc.maxBars * barSec, "SMC time stop");

   datetime bar = iTime(sym, g_smc.tf, 0);
   if(bar == 0 || bar == g_smcs[idx].lastBar)
      return false;
   g_smcs[idx].lastBar = bar;

   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(t.hour < g_smc.startHour || t.hour >= g_smc.endHour)
      return false;
   if(SymbolBusy(sym, magic))
      return false;

   const int W = 300;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(sym, g_smc.tf, 1, W, r);   // closed bars, oldest first
   int N = MathMax(1, g_smc.swingLen);
   if(n < N * 2 + 20)
      return false;

   double atr[];
   int kind[];
   SmcAtr(r, n, g_smc.atrPeriod, atr);
   SmcSwings(r, n, N, kind);

   int dir = 0; bool choch = false; double swept = 0;
   if(!SmcLastEvent(r, n, N, g_smc.closeConfirm, kind, dir, choch, swept))
      return false;
   if(g_smc.signalType == 1 && choch) return false;
   if(g_smc.signalType == 2 && !choch) return false;

   int e = n - 1;
   double a = atr[e];
   if(a <= 0 || MathAbs(r[e].close - r[e].open) < g_smc.atrFilter * a)
      return false;   // weak displacement

   // Entry zone
   double proximal = 0;
   bool found = false;
   if(g_smc.useOB)
     {
      for(int i = e; i >= MathMax(0, e - 20); i--)
        {
         bool opp = (dir > 0) ? (r[i].close < r[i].open) : (r[i].close > r[i].open);
         if(!opp)
            continue;
         double hi = g_smc.wickBounds ? r[i].high : MathMax(r[i].open, r[i].close);
         double lo = g_smc.wickBounds ? r[i].low  : MathMin(r[i].open, r[i].close);
         proximal = (dir > 0) ? hi : lo;
         found = true;
         break;
        }
     }
   else
     {
      double minGap = g_smc.fvgMinAtr * a;
      for(int k = e - 1; k >= MathMax(1, e - 20); k--)   // k+1 must be closed
        {
         if(dir > 0)
           {
            double gap = r[k + 1].low - r[k - 1].high;
            if(gap > 0 && gap >= minGap) { proximal = r[k + 1].low; found = true; break; }
           }
         else
           {
            double gap = r[k - 1].low - r[k + 1].high;
            if(gap > 0 && gap >= minGap) { proximal = r[k + 1].high; found = true; break; }
           }
        }
     }
   if(!found)
      return false;

   double stop = (dir > 0) ? swept - g_smc.stopBufferAtr * a : swept + g_smc.stopBufferAtr * a;
   double risk = (dir > 0) ? proximal - stop : stop - proximal;
   if(risk <= 0)
      return false;

   // Nearest confirmed liquidity pool beyond entry
   double liq = 0;
   bool hasLiq = false;
   for(int i = 0; i + N <= e; i++)
     {
      if(dir > 0 && (kind[i] & 1) != 0 && r[i].high > proximal && (!hasLiq || r[i].high < liq))
        { liq = r[i].high; hasLiq = true; }
      if(dir < 0 && (kind[i] & 2) != 0 && r[i].low < proximal && (!hasLiq || r[i].low > liq))
        { liq = r[i].low; hasLiq = true; }
     }
   double target = hasLiq ? liq : ((dir > 0) ? proximal + g_smc.rr * risk : proximal - g_smc.rr * risk);
   double plannedRR = MathAbs(target - proximal) / risk;
   if(plannedRR < g_smc.rr)
      return false;

   s.valid = true;
   s.dir = dir;
   s.entry = proximal;
   s.sl = stop;
   s.tp = target;
   s.tag = StringFormat("SMC %s %s", choch ? "CHoCH" : "BOS", sym);
   return true;
  }
//+------------------------------------------------------------------+
#endif
