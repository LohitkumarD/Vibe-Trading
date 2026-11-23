#ifndef PG_LABSTRATEGIES
#define PG_LABSTRATEGIES
//+------------------------------------------------------------------+
//| LabStrategies.mqh - seven intraday strategies on M1/M5           |
//|                                                                  |
//| All hours are SERVER time. Defaults fit GMT+2/+3 servers that     |
//| follow US daylight saving (FundedNext and most prop firms):       |
//|   London open 08:00 UK = 10:00 server, NY stock open 09:30 NY =   |
//|   16:30 server, Asian session ~ 02:00-09:00 server.               |
//|                                                                  |
//| L0 ORB-London   M5  30-min opening range at London open, trade    |
//|                     the first strong close outside it. 1.5R.      |
//| L1 ORB-NewYork  M5  same at the NY stock open.                    |
//| L2 VWAP-revert  M5  price stretched > 2 sd from the day's VWAP,   |
//|                     RSI(7) extreme and a rejection candle: fade   |
//|                     back to VWAP.                                 |
//| L3 Asia-BB-RSI2 M5  quiet Asian session (ADX < 22): close outside |
//|                     Bollinger(20, 2.2) with RSI(2) extreme, fade  |
//|                     to the middle band.                           |
//| L4 EMA-pullback M5  H1 trend (EMA50) + M5 EMA20 > EMA50, buy the  |
//|                     pullback that touches EMA20 and closes back   |
//|                     with the trend. 1.8R.                         |
//| L5 Asia-sweep   M5  London takes out the Asian high/low, then     |
//|                     closes back inside (stop hunt): trade the     |
//|                     reversal. 1.5R.                               |
//| L6 M1-EMA-scalp M1  London/NY overlap, M15 EMA50 trend, M1 EMA9/21|
//|                     cross with the trend. 1.5R, 30-min time stop. |
//+------------------------------------------------------------------+
#include "Lab.mqh"

struct LabHours
  {
   int               londonOpen;   // hour, default 10
   int               nyOpenHour;   // default 16
   int               nyOpenMin;    // default 30
   int               asiaStart;    // default 3
   int               asiaEnd;      // default 9 (exclusive)
  };

struct LabSymInd
  {
   int               atrM5;
   int               atrM1;
   int               atrH1;
   int               ema20M5;
   int               ema50M5;
   int               ema50H1;
   int               ema50M15;
   int               ema9M1;
   int               ema21M1;
   int               rsi7M5;
   int               rsi2M5;
   int               bbM5;
   int               adxM5;
   datetime          lastM5;
   datetime          lastM1;
   // per-day ranges
   long              orbDay[2];
   bool              orbReady[2];
   double            orbHi[2];
   double            orbLo[2];
   long              asiaDay;
   bool              asiaReady;
   double            asiaHi;
   double            asiaLo;
  };

LabHours  g_lh;
LabSymInd g_li[];

double LBuf(int handle, int buffer, int shift)
  {
   double v[];
   if(handle == INVALID_HANDLE || CopyBuffer(handle, buffer, shift, 1, v) != 1)
      return EMPTY_VALUE;
   return v[0];
  }

bool LRates(string sym, ENUM_TIMEFRAMES tf, int count, MqlRates &r[])
  {
   ArraySetAsSeries(r, true);
   return CopyRates(sym, tf, 0, count, r) == count;
  }

datetime LDayStart(datetime t) { long v = (long)t; return (datetime)(v - v % 86400); }

int LHour(datetime t) { MqlDateTime d; TimeToStruct(t, d); return d.hour; }
int LMin(datetime t)  { MqlDateTime d; TimeToStruct(t, d); return d.hour * 60 + d.min; }

bool LabInit(const LabConfig &cfg, const LabHours &hours, string &symbols[])
  {
   g_lh = hours;
   if(!LabInitCore(cfg, symbols))
      return false;
   int n = ArraySize(g_labSyms);
   ArrayResize(g_li, n);
   for(int i = 0; i < n; i++)
     {
      string s = g_labSyms[i];
      g_li[i].atrM5    = iATR(s, PERIOD_M5, 14);
      g_li[i].atrM1    = iATR(s, PERIOD_M1, 14);
      g_li[i].atrH1    = iATR(s, PERIOD_H1, 14);
      g_li[i].ema20M5  = iMA(s, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
      g_li[i].ema50M5  = iMA(s, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
      g_li[i].ema50H1  = iMA(s, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
      g_li[i].ema50M15 = iMA(s, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
      g_li[i].ema9M1   = iMA(s, PERIOD_M1, 9, 0, MODE_EMA, PRICE_CLOSE);
      g_li[i].ema21M1  = iMA(s, PERIOD_M1, 21, 0, MODE_EMA, PRICE_CLOSE);
      g_li[i].rsi7M5   = iRSI(s, PERIOD_M5, 7, PRICE_CLOSE);
      g_li[i].rsi2M5   = iRSI(s, PERIOD_M5, 2, PRICE_CLOSE);
      g_li[i].bbM5     = iBands(s, PERIOD_M5, 20, 0, 2.2, PRICE_CLOSE);
      g_li[i].adxM5    = iADX(s, PERIOD_M5, 14);
      g_li[i].lastM5 = 0;
      g_li[i].lastM1 = 0;
      g_li[i].orbDay[0] = 0; g_li[i].orbDay[1] = 0;
      g_li[i].orbReady[0] = false; g_li[i].orbReady[1] = false;
      g_li[i].asiaDay = 0;
      g_li[i].asiaReady = false;
      if(g_li[i].atrM5 == INVALID_HANDLE || g_li[i].bbM5 == INVALID_HANDLE || g_li[i].adxM5 == INVALID_HANDLE ||
         g_li[i].ema9M1 == INVALID_HANDLE || g_li[i].rsi2M5 == INVALID_HANDLE)
        {
         PrintFormat("PropGuard Lab: cannot create indicators for %s", s);
         return false;
        }
     }
   return true;
  }

void LabDeinit()
  {
   LabSaveState();
   for(int i = 0; i < ArraySize(g_li); i++)
     {
      IndicatorRelease(g_li[i].atrM5);   IndicatorRelease(g_li[i].atrM1);
      IndicatorRelease(g_li[i].atrH1);   IndicatorRelease(g_li[i].ema20M5);
      IndicatorRelease(g_li[i].ema50M5); IndicatorRelease(g_li[i].ema50H1);
      IndicatorRelease(g_li[i].ema50M15); IndicatorRelease(g_li[i].ema9M1);
      IndicatorRelease(g_li[i].ema21M1); IndicatorRelease(g_li[i].rsi7M5);
      IndicatorRelease(g_li[i].rsi2M5);  IndicatorRelease(g_li[i].bbM5);
      IndicatorRelease(g_li[i].adxM5);
     }
  }

bool LabOn(int s) { return g_labSt[s].mode != LAB_OFF; }

void LSignal(TradeSignal &sig, int dir, double sl, double tp)
  {
   ClearSignal(sig);
   sig.valid = true;
   sig.dir = dir;
   sig.sl = sl;
   sig.tp = tp;
   sig.entry = 0;
  }

//------------------------------------------------------------------
// L0 / L1 opening range breakout. k = 0 London, 1 New York.
//------------------------------------------------------------------
void LabOrb(int i, int k, const MqlRates &r[], bool active)
  {
   int s = k;                       // strategy id 0 or 1
   if(!LabOn(s))
      return;
   string sym = g_labSyms[i];
   datetime barT = r[1].time;
   datetime day = LDayStart(barT);
   int openMin = (k == 0) ? g_lh.londonOpen * 60 : g_lh.nyOpenHour * 60 + g_lh.nyOpenMin;
   int rangeEnd = openMin + 30;
   int tradeEnd = openMin + ((k == 0) ? 180 : 150);
   int m = LMin(barT);
   if(g_li[i].orbDay[k] != LabDayKey(day))
     {
      g_li[i].orbDay[k] = LabDayKey(day);
      g_li[i].orbReady[k] = false;
     }
   if(m < rangeEnd || m >= tradeEnd)
      return;
   if(!g_li[i].orbReady[k])
     {
      MqlRates rr[];
      datetime from = day + openMin * 60;
      datetime to = day + rangeEnd * 60 - 1;
      int got = CopyRates(sym, PERIOD_M5, from, to, rr);
      if(got < 5)
        { LabMarkDayDone(s, i); return; }
      double hi = rr[0].high, lo = rr[0].low;
      for(int j = 1; j < got; j++) { hi = MathMax(hi, rr[j].high); lo = MathMin(lo, rr[j].low); }
      double atrH1 = LBuf(g_li[i].atrH1, 0, 1);
      if(atrH1 == EMPTY_VALUE || hi - lo < 0.5 * atrH1 || hi - lo > 2.5 * atrH1)
        { LabMarkDayDone(s, i); return; }
      g_li[i].orbHi[k] = hi;
      g_li[i].orbLo[k] = lo;
      g_li[i].orbReady[k] = true;
     }
   if(!LabSignalAllowed(s, i, 0))
      return;
   double hi = g_li[i].orbHi[k], lo = g_li[i].orbLo[k], h = hi - lo, mid = (hi + lo) / 2.0;
   double body = MathAbs(r[1].close - r[1].open), rng = r[1].high - r[1].low;
   if(rng <= 0 || body < 0.5 * rng)
      return;
   TradeSignal sig;
   if(r[1].close > hi && r[1].close < hi + 0.5 * h && r[1].close > r[1].open)
     {
      double sl = mid;
      LSignal(sig, 1, sl, r[1].close + 1.5 * (r[1].close - sl));
     }
   else if(r[1].close < lo && r[1].close > lo - 0.5 * h && r[1].close < r[1].open)
     {
      double sl = mid;
      LSignal(sig, -1, sl, r[1].close - 1.5 * (sl - r[1].close));
     }
   else
      return;
   LabRoute(s, i, sig, 4 * 3600, active);
   LabMarkDayDone(s, i);             // one breakout per day
  }

//------------------------------------------------------------------
// L2 VWAP reversion
//------------------------------------------------------------------
void LabVwap(int i, const MqlRates &r[], bool active)
  {
   int s = 2;
   if(!LabOn(s))
      return;
   int m = LMin(r[1].time);
   if(m < g_lh.londonOpen * 60 || m >= 20 * 60)
      return;
   if(!LabSignalAllowed(s, i, 30 * 60))
      return;
   string sym = g_labSyms[i];
   datetime day = LDayStart(r[1].time);
   MqlRates d[];
   int got = CopyRates(sym, PERIOD_M5, day + 3600, r[1].time, d);   // skip the rollover hour
   if(got < 24)
      return;
   double sv = 0, spv = 0;
   for(int j = 0; j < got; j++)
     {
      double tp = (d[j].high + d[j].low + d[j].close) / 3.0;
      double v = (double)MathMax((long)1, d[j].tick_volume);
      sv += v; spv += v * tp;
     }
   double vwap = spv / sv, var = 0;
   for(int j = 0; j < got; j++)
     {
      double tp = (d[j].high + d[j].low + d[j].close) / 3.0;
      double v = (double)MathMax((long)1, d[j].tick_volume);
      var += v * (tp - vwap) * (tp - vwap);
     }
   double sd = MathSqrt(var / sv);
   double rsi = LBuf(g_li[i].rsi7M5, 0, 1);
   double atr = LBuf(g_li[i].atrM5, 0, 1);
   if(sd <= 0 || rsi == EMPTY_VALUE || atr == EMPTY_VALUE)
      return;
   double c = r[1].close;
   TradeSignal sig;
   if(c > vwap + 2.0 * sd && rsi > 75 && r[1].close < r[1].open)
     {
      double sl = MathMax(r[1].high, MathMax(r[2].high, r[3].high)) + 0.3 * atr;
      if(c - vwap < 0.8 * (sl - c)) return;
      LSignal(sig, -1, sl, vwap);
     }
   else if(c < vwap - 2.0 * sd && rsi < 25 && r[1].close > r[1].open)
     {
      double sl = MathMin(r[1].low, MathMin(r[2].low, r[3].low)) - 0.3 * atr;
      if(vwap - c < 0.8 * (c - sl)) return;
      LSignal(sig, 1, sl, vwap);
     }
   else
      return;
   LabRoute(s, i, sig, 2 * 3600, active);
  }

//------------------------------------------------------------------
// L3 Asian session Bollinger + RSI(2) fade
//------------------------------------------------------------------
void LabAsiaBb(int i, const MqlRates &r[], bool active)
  {
   int s = 3;
   if(!LabOn(s))
      return;
   int h = LHour(r[1].time);
   if(h < 2 || h >= g_lh.asiaEnd)
      return;
   if(!LabSignalAllowed(s, i, 30 * 60))
      return;
   double adx = LBuf(g_li[i].adxM5, 0, 1);
   double up = LBuf(g_li[i].bbM5, 1, 1), lo = LBuf(g_li[i].bbM5, 2, 1), mid = LBuf(g_li[i].bbM5, 0, 1);
   double rsi = LBuf(g_li[i].rsi2M5, 0, 1);
   double atr = LBuf(g_li[i].atrM5, 0, 1);
   if(adx == EMPTY_VALUE || up == EMPTY_VALUE || rsi == EMPTY_VALUE || atr == EMPTY_VALUE || adx >= 22)
      return;
   double c = r[1].close;
   TradeSignal sig;
   if(c < lo && rsi < 10)
     {
      double sl = c - 1.5 * atr;
      if(mid - c < 0.6 * (c - sl)) return;
      LSignal(sig, 1, sl, mid);
     }
   else if(c > up && rsi > 90)
     {
      double sl = c + 1.5 * atr;
      if(c - mid < 0.6 * (sl - c)) return;
      LSignal(sig, -1, sl, mid);
     }
   else
      return;
   LabRoute(s, i, sig, 90 * 60, active);
  }

//------------------------------------------------------------------
// L4 M5 EMA pullback with the H1 trend
//------------------------------------------------------------------
void LabEmaPullback(int i, const MqlRates &r[], bool active)
  {
   int s = 4;
   if(!LabOn(s))
      return;
   int h = LHour(r[1].time);
   if(h < g_lh.londonOpen || h >= 19)
      return;
   if(!LabSignalAllowed(s, i, 60 * 60))
      return;
   string sym = g_labSyms[i];
   double e50h1 = LBuf(g_li[i].ema50H1, 0, 1), e50h1old = LBuf(g_li[i].ema50H1, 0, 4);
   double e20 = LBuf(g_li[i].ema20M5, 0, 1), e50 = LBuf(g_li[i].ema50M5, 0, 1);
   double atr = LBuf(g_li[i].atrM5, 0, 1);
   double h1c = iClose(sym, PERIOD_H1, 1);
   if(e50h1 == EMPTY_VALUE || e50h1old == EMPTY_VALUE || e20 == EMPTY_VALUE || e50 == EMPTY_VALUE || atr == EMPTY_VALUE || h1c <= 0)
      return;
   TradeSignal sig;
   if(h1c > e50h1 && e50h1 > e50h1old && e20 > e50 &&
      r[1].low <= e20 && r[1].close > e20 && r[1].close > r[1].open && r[2].close > e50)
     {
      double lowest = r[1].low;
      for(int j = 2; j <= 6; j++) lowest = MathMin(lowest, r[j].low);
      double sl = lowest - 0.2 * atr;
      double dist = r[1].close - sl;
      if(dist < 0.5 * atr || dist > 2.5 * atr) return;
      LSignal(sig, 1, sl, r[1].close + 1.8 * dist);
     }
   else if(h1c < e50h1 && e50h1 < e50h1old && e20 < e50 &&
           r[1].high >= e20 && r[1].close < e20 && r[1].close < r[1].open && r[2].close < e50)
     {
      double highest = r[1].high;
      for(int j = 2; j <= 6; j++) highest = MathMax(highest, r[j].high);
      double sl = highest + 0.2 * atr;
      double dist = sl - r[1].close;
      if(dist < 0.5 * atr || dist > 2.5 * atr) return;
      LSignal(sig, -1, sl, r[1].close - 1.8 * dist);
     }
   else
      return;
   LabRoute(s, i, sig, 3 * 3600, active);
  }

//------------------------------------------------------------------
// L5 Asian range sweep and reclaim (stop hunt reversal)
//------------------------------------------------------------------
void LabAsiaSweep(int i, const MqlRates &r[], bool active)
  {
   int s = 5;
   if(!LabOn(s))
      return;
   string sym = g_labSyms[i];
   datetime day = LDayStart(r[1].time);
   int h = LHour(r[1].time);
   if(h < g_lh.asiaEnd || h >= g_lh.londonOpen + 3)
      return;
   if(g_li[i].asiaDay != LabDayKey(day))
     {
      g_li[i].asiaDay = LabDayKey(day);
      g_li[i].asiaReady = false;
      MqlRates a[];
      int got = CopyRates(sym, PERIOD_M5, day + g_lh.asiaStart * 3600, day + g_lh.asiaEnd * 3600 - 1, a);
      double atrH1 = LBuf(g_li[i].atrH1, 0, 1);
      if(got >= 36 && atrH1 != EMPTY_VALUE)
        {
         double hi = a[0].high, lo = a[0].low;
         for(int j = 1; j < got; j++) { hi = MathMax(hi, a[j].high); lo = MathMin(lo, a[j].low); }
         if(hi - lo >= 1.0 * atrH1 && hi - lo <= 5.0 * atrH1)
           { g_li[i].asiaHi = hi; g_li[i].asiaLo = lo; g_li[i].asiaReady = true; }
        }
     }
   if(!g_li[i].asiaReady || !LabSignalAllowed(s, i, 0))
      return;
   double hi = g_li[i].asiaHi, lo = g_li[i].asiaLo, rg = hi - lo, buf = 0.1 * rg;
   double atr = LBuf(g_li[i].atrM5, 0, 1);
   if(atr == EMPTY_VALUE)
      return;
   double hh = MathMax(r[1].high, MathMax(r[2].high, r[3].high));
   double ll = MathMin(r[1].low, MathMin(r[2].low, r[3].low));
   TradeSignal sig;
   if(hh > hi + buf && r[1].close < hi && r[1].close < r[1].open)
     {
      double sl = hh + 0.2 * atr;
      LSignal(sig, -1, sl, r[1].close - 1.5 * (sl - r[1].close));
     }
   else if(ll < lo - buf && r[1].close > lo && r[1].close > r[1].open)
     {
      double sl = ll - 0.2 * atr;
      LSignal(sig, 1, sl, r[1].close + 1.5 * (r[1].close - sl));
     }
   else
      return;
   LabRoute(s, i, sig, 4 * 3600, active);
   LabMarkDayDone(s, i);
  }

//------------------------------------------------------------------
// L6 M1 EMA 9/21 cross with the M15 trend, London/NY overlap
//------------------------------------------------------------------
void LabM1Scalp(int i, const MqlRates &r[], bool active)
  {
   int s = 6;
   if(!LabOn(s))
      return;
   int h = LHour(r[1].time);
   if(h < 15 || h >= 19)
      return;
   if(!LabSignalAllowed(s, i, 20 * 60))
      return;
   string sym = g_labSyms[i];
   double f1 = LBuf(g_li[i].ema9M1, 0, 1), f2 = LBuf(g_li[i].ema9M1, 0, 2);
   double s1 = LBuf(g_li[i].ema21M1, 0, 1), s2 = LBuf(g_li[i].ema21M1, 0, 2);
   double t15 = LBuf(g_li[i].ema50M15, 0, 1);
   double c15 = iClose(sym, PERIOD_M15, 1);
   double atr = LBuf(g_li[i].atrM1, 0, 1);
   if(f1 == EMPTY_VALUE || f2 == EMPTY_VALUE || s1 == EMPTY_VALUE || s2 == EMPTY_VALUE ||
      t15 == EMPTY_VALUE || atr == EMPTY_VALUE || c15 <= 0)
      return;
   TradeSignal sig;
   if(c15 > t15 && f1 > s1 && f2 <= s2 && r[1].close > f1)
     {
      double lowest = r[1].low;
      for(int j = 2; j <= 5; j++) lowest = MathMin(lowest, r[j].low);
      double sl = lowest - 0.3 * atr;
      double dist = r[1].close - sl;
      if(dist < 1.0 * atr || dist > 4.0 * atr) return;
      LSignal(sig, 1, sl, r[1].close + 1.5 * dist);
     }
   else if(c15 < t15 && f1 < s1 && f2 >= s2 && r[1].close < f1)
     {
      double highest = r[1].high;
      for(int j = 2; j <= 5; j++) highest = MathMax(highest, r[j].high);
      double sl = highest + 0.3 * atr;
      double dist = sl - r[1].close;
      if(dist < 1.0 * atr || dist > 4.0 * atr) return;
      LSignal(sig, -1, sl, r[1].close - 1.5 * dist);
     }
   else
      return;
   LabRoute(s, i, sig, 30 * 60, active);
  }

//------------------------------------------------------------------
// Main entry: call on every tick/timer
//------------------------------------------------------------------
void LabRun(bool active)
  {
   LabUpdatePaper();
   LabUpdateLive();
   LabMaybeReport();
   for(int i = 0; i < ArraySize(g_labSyms); i++)
     {
      string sym = g_labSyms[i];
      datetime t5 = iTime(sym, PERIOD_M5, 0);
      if(t5 > 0 && t5 != g_li[i].lastM5)
        {
         MqlRates r[];
         if(LRates(sym, PERIOD_M5, 8, r))
           {
            g_li[i].lastM5 = t5;
            LabOrb(i, 0, r, active);
            LabOrb(i, 1, r, active);
            LabVwap(i, r, active);
            LabAsiaBb(i, r, active);
            LabEmaPullback(i, r, active);
            LabAsiaSweep(i, r, active);
           }
        }
      datetime t1 = iTime(sym, PERIOD_M1, 0);
      if(t1 > 0 && t1 != g_li[i].lastM1)
        {
         MqlRates r[];
         if(LRates(sym, PERIOD_M1, 8, r))
           {
            g_li[i].lastM1 = t1;
            LabM1Scalp(i, r, active);
           }
        }
     }
  }
//+------------------------------------------------------------------+
#endif
