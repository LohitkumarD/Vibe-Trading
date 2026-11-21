#ifndef PG_LONDONBREAKOUT
#define PG_LONDONBREAKOUT
//+------------------------------------------------------------------+
//| LondonBreakout.mqh - Strategy A                                  |
//|                                                                  |
//| 1. Asian range: high/low of M15 bars between RangeStart and      |
//|    RangeEnd (server time).                                       |
//| 2. Skip the day if the range is too small or too big compared    |
//|    with the daily ATR (no edge / stop too wide).                 |
//| 3. In the trade window, when an M15 bar CLOSES beyond the range  |
//|    by a buffer, enter in that direction.                         |
//| 4. Stop at the opposite side of the range (+ buffer).            |
//|    Target = RR x stop distance. One trade per symbol per day.    |
//| 5. Anything still open at ExitHour is closed (time stop).        |
//|                                                                  |
//| Default hours fit brokers on GMT+2/+3 "New York close" servers   |
//| (most prop firms): London 08:00 open = 10:00 server all year.    |
//+------------------------------------------------------------------+
#include "../Executor.mqh"

struct LbConfig
  {
   int               rangeStartHour;   // server time, inclusive
   int               rangeEndHour;     // server time, exclusive
   int               tradeEndHour;     // no new entries from this hour
   int               exitHour;         // close open trades at this hour
   double            minRangeAtr;      // range >= this x ATR(D1)
   double            maxRangeAtr;      // range <= this x ATR(D1)
   double            bufferFrac;       // breakout buffer as fraction of range
   double            rr;               // target in R
   bool              trendFilter;      // only break in the direction of the H4 EMA200
  };

struct LbSymbolState
  {
   string            sym;
   int               atrHandle;
   int               emaHandle;
   datetime          lastBar;
   datetime          day;
   bool              rangeReady;
   bool              dayDone;
   double            hi;
   double            lo;
  };

LbConfig      g_lb;
LbSymbolState g_lbs[];

datetime DayStart(datetime t) { long v = (long)t; return (datetime)(v - v % 86400); }

bool LbInit(const LbConfig &cfg, string &symbols[])
  {
   g_lb = cfg;
   int n = ArraySize(symbols);
   ArrayResize(g_lbs, n);
   for(int i = 0; i < n; i++)
     {
      g_lbs[i].sym = symbols[i];
      g_lbs[i].atrHandle = iATR(symbols[i], PERIOD_D1, 14);
      g_lbs[i].emaHandle = iMA(symbols[i], PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);
      g_lbs[i].lastBar = 0;
      g_lbs[i].day = 0;
      g_lbs[i].rangeReady = false;
      g_lbs[i].dayDone = false;
      if(g_lbs[i].atrHandle == INVALID_HANDLE || g_lbs[i].emaHandle == INVALID_HANDLE)
        {
         PrintFormat("LondonBreakout: cannot create ATR for %s", symbols[i]);
         return false;
        }
     }
   return true;
  }

void LbDeinit()
  {
   for(int i = 0; i < ArraySize(g_lbs); i++)
     {
      if(g_lbs[i].atrHandle != INVALID_HANDLE)
         IndicatorRelease(g_lbs[i].atrHandle);
      if(g_lbs[i].emaHandle != INVALID_HANDLE)
         IndicatorRelease(g_lbs[i].emaHandle);
     }
  }

bool LbBuildRange(LbSymbolState &st, datetime day)
  {
   MqlRates r[];
   datetime from = day + g_lb.rangeStartHour * 3600;
   datetime to   = day + g_lb.rangeEndHour * 3600 - 1;
   int got = CopyRates(st.sym, PERIOD_M15, from, to, r);
   if(got < 4)
      return false;
   st.hi = r[0].high;
   st.lo = r[0].low;
   for(int i = 1; i < got; i++)
     {
      st.hi = MathMax(st.hi, r[i].high);
      st.lo = MathMin(st.lo, r[i].low);
     }
   double atr[];
   if(CopyBuffer(st.atrHandle, 0, 1, 1, atr) != 1)
      return false;
   double h = st.hi - st.lo;
   if(h < g_lb.minRangeAtr * atr[0] || h > g_lb.maxRangeAtr * atr[0])
     {
      PrintFormat("LondonBreakout %s: range %.5f outside %.2f-%.2f x ATR %.5f, no trade today",
                  st.sym, h, g_lb.minRangeAtr, g_lb.maxRangeAtr, atr[0]);
      st.dayDone = true;
     }
   return true;
  }

//--- Run on every tick/timer for each symbol. Returns true when a signal fires.
bool LbCheck(int idx, long magic, TradeSignal &s)
  {
   ClearSignal(s);
   LbSymbolState st = g_lbs[idx];
   string sym = st.sym;

   datetime now = TimeCurrent();
   datetime day = DayStart(now);
   if(day != st.day)
     {
      st.day = day;
      st.rangeReady = false;
      st.dayDone = false;
     }
   MqlDateTime t; TimeToStruct(now, t);

   // Time stop
   if(t.hour >= g_lb.exitHour)
      TimeStopOwn(sym, magic, "LB", 0, "end-of-day time stop");

   // Only act once per closed M15 bar
   datetime bar = iTime(sym, PERIOD_M15, 0);
   if(bar == 0 || bar == st.lastBar)
     { g_lbs[idx] = st; return s.valid; }
   st.lastBar = bar;

   if(st.dayDone || t.hour < g_lb.rangeEndHour || t.hour >= g_lb.tradeEndHour)
     { g_lbs[idx] = st; return s.valid; }

   if(!st.rangeReady)
     {
      if(!LbBuildRange(st, day))
        { g_lbs[idx] = st; return s.valid; }
      st.rangeReady = true;
      if(st.dayDone)
        { g_lbs[idx] = st; return s.valid; }
     }

   if(SymbolBusy(sym, magic))
     { g_lbs[idx] = st; return s.valid; }

   double close1 = iClose(sym, PERIOD_M15, 1);
   double h = st.hi - st.lo;
   double buf = h * g_lb.bufferFrac;
   if(close1 > st.hi + buf)
     {
      s.dir = +1;
      s.sl = st.lo - buf;
      double entry = SymbolInfoDouble(sym, SYMBOL_ASK);
      s.tp = entry + (entry - s.sl) * g_lb.rr;
     }
   else if(close1 < st.lo - buf)
     {
      s.dir = -1;
      s.sl = st.hi + buf;
      double entry = SymbolInfoDouble(sym, SYMBOL_BID);
      s.tp = entry - (s.sl - entry) * g_lb.rr;
     }
   if(s.dir != 0 && g_lb.trendFilter)
     {
      double ema[];
      double c4 = iClose(sym, PERIOD_H4, 1);
      if(CopyBuffer(st.emaHandle, 0, 1, 1, ema) != 1 || c4 <= 0)
         s.dir = 0;
      else if((s.dir > 0 && c4 < ema[0]) || (s.dir < 0 && c4 > ema[0]))
        {
         st.dayDone = true;   // breakout against the H4 trend: skip the day
         s.dir = 0;
        }
     }
   if(s.dir != 0)
     {
      s.valid = true;
      s.tag = "LB " + sym;
      st.dayDone = true;   // one attempt per symbol per day, filled or not
     }
   g_lbs[idx] = st;
   return s.valid;
  }
//+------------------------------------------------------------------+
#endif
