#ifndef PG_NEWSFILTER
#define PG_NEWSFILTER
//+------------------------------------------------------------------+
//| NewsFilter.mqh - block entries around high-impact news           |
//| Uses MT5's built-in economic calendar. The calendar is NOT       |
//| available in the Strategy Tester, so the filter is off there.    |
//+------------------------------------------------------------------+

datetime g_newsCheckedAt = 0;
string   g_newsCheckedSym = "";
bool     g_newsBlocked = false;
string   g_newsReason = "";

bool CurrencyHasHighImpactNear(string currency, datetime now, int windowMin, string &reason)
  {
   MqlCalendarValue values[];
   datetime from = now - windowMin * 60;
   datetime to   = now + windowMin * 60;
   if(CalendarValueHistory(values, from, to, NULL, currency) <= 0)
      return false;
   for(int i = 0; i < ArraySize(values); i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
        {
         reason = currency + " " + ev.name + " at " + TimeToString(values[i].time, TIME_MINUTES);
         return true;
        }
     }
   return false;
  }

//--- true = do not open new trades on this symbol now
bool NewsBlocks(string symbol, int windowMin, string &reason)
  {
   if(windowMin <= 0 || MQLInfoInteger(MQL_TESTER))
      return false;
   datetime now = TimeTradeServer();   // calendar times are server time
   if(symbol == g_newsCheckedSym && now - g_newsCheckedAt < 60)
     {
      reason = g_newsReason;
      return g_newsBlocked;
     }
   g_newsCheckedSym = symbol;
   g_newsCheckedAt = now;
   g_newsBlocked = false;
   g_newsReason = "";
   string base   = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   string profit = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   if(CurrencyHasHighImpactNear(base, now, windowMin, g_newsReason) ||
      (profit != base && CurrencyHasHighImpactNear(profit, now, windowMin, g_newsReason)))
      g_newsBlocked = true;
   reason = g_newsReason;
   return g_newsBlocked;
  }
//+------------------------------------------------------------------+
#endif
