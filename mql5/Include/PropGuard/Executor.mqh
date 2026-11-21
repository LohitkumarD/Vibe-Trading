#ifndef PG_EXECUTOR
#define PG_EXECUTOR
//+------------------------------------------------------------------+
//| Executor.mqh - sizing and sending orders                         |
//| Every order is sent WITH its stop-loss and take-profit, so they  |
//| sit on the broker's server even if the laptop goes offline.      |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
#include "RiskGuard.mqh"

struct TradeSignal
  {
   bool              valid;
   int               dir;      // +1 buy, -1 sell
   double            sl;
   double            tp;
   string            tag;
  };

CTrade g_exec;

//--- Lots so that hitting the stop loses `riskMoney`. 0 = cannot size.
double LotsForRisk(string sym, int dir, double entry, double sl, double riskMoney, double maxLots)
  {
   double lossPerLot = 0.0;
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(ot, sym, 1.0, entry, sl, lossPerLot))
      return 0.0;
   lossPerLot = MathAbs(lossPerLot);
   if(lossPerLot <= 0.0)
      return 0.0;
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lots = MathFloor((riskMoney / lossPerLot) / step) * step;   // round DOWN
   lots = MathMin(lots, MathMin(vmax, maxLots));
   if(lots < vmin)
      return 0.0;     // account too small for this stop: skip, never round up
   return NormalizeDouble(lots, 2);
  }

//--- Size, ask the guard, then send. Returns true if an order was placed.
bool ExecuteSignal(const TradeSignal &s, string sym, double riskPct, double maxLots,
                   double maxSpreadPts, long magic, int deviationPts)
  {
   if(!s.valid)
      return false;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double spreadPts = (ask - bid) / point;
   if(maxSpreadPts > 0 && spreadPts > maxSpreadPts)
     {
      Notify(StringFormat("skip %s: spread %.0f pts > %.0f", s.tag, spreadPts, maxSpreadPts), false);
      return false;
     }
   double entry = (s.dir > 0) ? ask : bid;
   double sl = NormalizeDouble(s.sl, digits);
   double tp = NormalizeDouble(s.tp, digits);
   if(sl <= 0 || (s.dir > 0 && sl >= entry) || (s.dir < 0 && sl <= entry))
     {
      Notify("skip " + s.tag + ": stop is on the wrong side of price", false);
      return false;
     }
   long stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   if(MathAbs(entry - sl) / point < stopsLevel || (tp > 0 && MathAbs(tp - entry) / point < stopsLevel))
     {
      Notify("skip " + s.tag + ": stop/target closer than broker minimum", false);
      return false;
     }

   double riskMoney = GuardInitialBalance() * riskPct / 100.0;
   double lots = LotsForRisk(sym, s.dir, entry, sl, riskMoney, maxLots);
   if(lots <= 0.0)
     {
      Notify("skip " + s.tag + ": account too small for this stop at the set risk", false);
      return false;
     }
   // Real risk after rounding the lots down
   double realRisk = 0.0;
   ENUM_ORDER_TYPE ot = (s.dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcProfit(ot, sym, lots, entry, sl, realRisk))
      realRisk = MathAbs(realRisk);
   else
      realRisk = riskMoney;

   string why = "";
   if(!GuardCanOpen(realRisk, why))
     {
      Notify("skip " + s.tag + ": " + why, false);
      return false;
     }

   g_exec.SetExpertMagicNumber(magic);
   g_exec.SetDeviationInPoints(deviationPts);
   bool ok = (s.dir > 0) ? g_exec.Buy(lots, sym, 0.0, sl, tp, s.tag)
                         : g_exec.Sell(lots, sym, 0.0, sl, tp, s.tag);
   if(ok && (g_exec.ResultRetcode() == TRADE_RETCODE_DONE || g_exec.ResultRetcode() == TRADE_RETCODE_PLACED))
     {
      GuardOnEntry();
      Notify(StringFormat("%s %s %.2f lots, SL %s, TP %s, risk %.2f",
                          s.dir > 0 ? "BUY" : "SELL", s.tag, lots,
                          DoubleToString(sl, digits), DoubleToString(tp, digits), realRisk));
      return true;
     }
   Notify(StringFormat("order failed for %s: %d %s", s.tag, g_exec.ResultRetcode(), g_exec.ResultRetcodeDescription()));
   return false;
  }

int CountOwnPositions(string sym, long magic)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == sym)
         n++;
     }
   return n;
  }

void CloseOwnPositions(string sym, long magic, string why)
  {
   g_exec.SetExpertMagicNumber(magic);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == sym)
         if(g_exec.PositionClose(t))
            Notify("closed " + sym + ": " + why);
     }
  }
//+------------------------------------------------------------------+
#endif
