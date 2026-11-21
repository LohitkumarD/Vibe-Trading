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
   double            entry;    // 0 = market now, >0 = limit order at this price
   string            tag;
  };

void ClearSignal(TradeSignal &s)
  {
   s.valid = false; s.dir = 0; s.sl = 0; s.tp = 0; s.entry = 0; s.tag = "";
  }

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
   bool useLimit = false;
   if(s.entry > 0)
     {
      double lim = NormalizeDouble(s.entry, digits);
      long lvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
      // A limit only makes sense if price has not reached it yet
      if((s.dir > 0 && ask - lim > lvl * point) || (s.dir < 0 && lim - bid > lvl * point))
        { entry = lim; useLimit = true; }
     }
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
   bool ok;
   if(useLimit)
      ok = (s.dir > 0) ? g_exec.BuyLimit(lots, entry, sym, sl, tp, ORDER_TIME_GTC, 0, s.tag)
                       : g_exec.SellLimit(lots, entry, sym, sl, tp, ORDER_TIME_GTC, 0, s.tag);
   else
      ok = (s.dir > 0) ? g_exec.Buy(lots, sym, 0.0, sl, tp, s.tag)
                       : g_exec.Sell(lots, sym, 0.0, sl, tp, s.tag);
   if(ok && (g_exec.ResultRetcode() == TRADE_RETCODE_DONE || g_exec.ResultRetcode() == TRADE_RETCODE_PLACED))
     {
      GuardOnEntry();
      Notify(StringFormat("%s%s %s %.2f lots, SL %s, TP %s, risk %.2f",
                          s.dir > 0 ? "BUY" : "SELL", useLimit ? " LIMIT" : "", s.tag, lots,
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

int CountOwnOrders(string sym, long magic)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) == magic && OrderGetString(ORDER_SYMBOL) == sym)
         n++;
     }
   return n;
  }

//--- Busy = we already have a trade or a waiting order on this symbol
bool SymbolBusy(string sym, long magic)
  {
   return CountOwnPositions(sym, magic) + CountOwnOrders(sym, magic) > 0;
  }

//--- Delete our pending orders whose comment starts with `prefix` and are older than maxAgeSec
void ExpireOwnOrders(string sym, long magic, string prefix, int maxAgeSec)
  {
   g_exec.SetExpertMagicNumber(magic);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic || OrderGetString(ORDER_SYMBOL) != sym)
         continue;
      if(StringFind(OrderGetString(ORDER_COMMENT), prefix) != 0)
         continue;
      if(TimeCurrent() - (datetime)OrderGetInteger(ORDER_TIME_SETUP) >= maxAgeSec)
         g_exec.OrderDelete(t);
     }
  }

//--- Close our positions (by comment prefix) held longer than maxAgeSec
void TimeStopOwn(string sym, long magic, string prefix, int maxAgeSec, string why)
  {
   g_exec.SetExpertMagicNumber(magic);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic || PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), prefix) != 0)
         continue;
      if(TimeCurrent() - (datetime)PositionGetInteger(POSITION_TIME) >= maxAgeSec)
         if(g_exec.PositionClose(t))
            Notify("closed " + sym + ": " + why);
     }
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
