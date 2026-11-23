#ifndef PG_TRENDPULLBACK
#define PG_TRENDPULLBACK
//+------------------------------------------------------------------+
//| TrendPullback.mqh - Strategy B                                   |
//|                                                                  |
//| Trend (H4): EMA50 above EMA200 and H4 close above EMA50 = up.    |
//| Entry (H1, on bar close): the bar dipped to/through EMA20 but    |
//| closed back above it as a bullish candle (mirror for shorts).    |
//| Stop: lowest low of the last 5 H1 bars - 0.3 ATR, and the stop   |
//| distance must be 0.5-3 ATR. Target: rr x risk. Time stop.        |
//+------------------------------------------------------------------+
#include "../Executor.mqh"

struct TpConfig
  {
   double            rr;
   int               startHour;   // server time window for entries
   int               endHour;
   int               maxHoldHours;
  };

struct TpSymState
  {
   string            sym;
   datetime          lastBar;
   int               hFast4, hSlow4, hEma1, hAtr1;
  };

TpConfig   g_tp;
TpSymState g_tps[];

bool TpInit(const TpConfig &cfg, string &symbols[])
  {
   g_tp = cfg;
   ArrayResize(g_tps, ArraySize(symbols));
   for(int i = 0; i < ArraySize(symbols); i++)
     {
      string s = symbols[i];
      g_tps[i].sym = s;
      g_tps[i].lastBar = 0;
      g_tps[i].hFast4 = iMA(s, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);
      g_tps[i].hSlow4 = iMA(s, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);
      g_tps[i].hEma1  = iMA(s, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
      g_tps[i].hAtr1  = iATR(s, PERIOD_H1, 14);
      if(g_tps[i].hFast4 == INVALID_HANDLE || g_tps[i].hSlow4 == INVALID_HANDLE ||
         g_tps[i].hEma1 == INVALID_HANDLE || g_tps[i].hAtr1 == INVALID_HANDLE)
         return false;
     }
   return true;
  }

void TpDeinit()
  {
   for(int i = 0; i < ArraySize(g_tps); i++)
     {
      IndicatorRelease(g_tps[i].hFast4);
      IndicatorRelease(g_tps[i].hSlow4);
      IndicatorRelease(g_tps[i].hEma1);
      IndicatorRelease(g_tps[i].hAtr1);
     }
  }

double Buf1(int handle, int shift)
  {
   double v[];
   if(CopyBuffer(handle, 0, shift, 1, v) != 1)
      return 0.0;
   return v[0];
  }

bool TpCheck(int idx, long magic, TradeSignal &s)
  {
   ClearSignal(s);
   TpSymState st = g_tps[idx];
   string sym = st.sym;
   TimeStopOwn(sym, magic, "TP ", g_tp.maxHoldHours * 3600, "trend-pullback time stop");

   datetime bar = iTime(sym, PERIOD_H1, 0);
   if(bar == 0 || bar == st.lastBar)
      return false;
   g_tps[idx].lastBar = bar;

   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(t.hour < g_tp.startHour || t.hour >= g_tp.endHour)
      return false;
   if(SymbolBusy(sym, magic))
      return false;

   double fast4 = Buf1(st.hFast4, 1), slow4 = Buf1(st.hSlow4, 1);
   double c4 = iClose(sym, PERIOD_H4, 1);
   double ema1 = Buf1(st.hEma1, 1), atr = Buf1(st.hAtr1, 1);
   if(fast4 <= 0 || slow4 <= 0 || ema1 <= 0 || atr <= 0 || c4 <= 0)
      return false;

   double o = iOpen(sym, PERIOD_H1, 1), h = iHigh(sym, PERIOD_H1, 1);
   double l = iLow(sym, PERIOD_H1, 1),  c = iClose(sym, PERIOD_H1, 1);

   int dir = 0;
   if(fast4 > slow4 && c4 > fast4 && l <= ema1 && c > ema1 && c > o)
      dir = 1;
   else if(fast4 < slow4 && c4 < fast4 && h >= ema1 && c < ema1 && c < o)
      dir = -1;
   if(dir == 0)
      return false;

   int lo = iLowest(sym, PERIOD_H1, MODE_LOW, 5, 1);
   int hi = iHighest(sym, PERIOD_H1, MODE_HIGH, 5, 1);
   if(lo < 0 || hi < 0)
      return false;
   double entry = (dir > 0) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   double sl = (dir > 0) ? iLow(sym, PERIOD_H1, lo) - 0.3 * atr : iHigh(sym, PERIOD_H1, hi) + 0.3 * atr;
   double risk = MathAbs(entry - sl);
   if(risk < 0.5 * atr || risk > 3.0 * atr)
      return false;

   s.valid = true;
   s.dir = dir;
   s.sl = sl;
   s.tp = (dir > 0) ? entry + g_tp.rr * risk : entry - g_tp.rr * risk;
   s.tag = "TP " + sym;
   return true;
  }
//+------------------------------------------------------------------+
#endif
