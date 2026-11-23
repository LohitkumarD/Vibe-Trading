#ifndef PG_STATESTORE
#define PG_STATESTORE
//+------------------------------------------------------------------+
//| StateStore.mqh - risk state that survives restarts               |
//| Saved as key=value text in MQL5\Files\PropGuard_<login>.txt      |
//+------------------------------------------------------------------+

struct GuardState
  {
   long              dayKey;          // firm-local date as yyyymmdd
   double            dayAnchor;       // balance/equity the daily loss counts from
   double            initialBalance;  // account starting balance
   double            peakBalance;     // balance high-water mark (trailing max loss)
   double            dayLowEquity;    // worst equity seen today (for reports)
   int               tradesToday;
   int               lossesToday;
   bool              dayLocked;       // no more trading until next reset
   bool              accountLocked;   // max-loss guard hit, needs manual reset
   bool              paused;          // paused from the panel or by a manual close
  };

string StateFileName()
  {
   return StringFormat("PropGuard_%I64d.txt", AccountInfoInteger(ACCOUNT_LOGIN));
  }

bool SaveState(const GuardState &s)
  {
   int h = FileOpen(StateFileName(), FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("PropGuard: cannot save state (%d)", GetLastError());
      return false;
     }
   FileWriteString(h, StringFormat("dayKey=%I64d\n", s.dayKey));
   FileWriteString(h, StringFormat("dayAnchor=%.2f\n", s.dayAnchor));
   FileWriteString(h, StringFormat("initialBalance=%.2f\n", s.initialBalance));
   FileWriteString(h, StringFormat("peakBalance=%.2f\n", s.peakBalance));
   FileWriteString(h, StringFormat("dayLowEquity=%.2f\n", s.dayLowEquity));
   FileWriteString(h, StringFormat("tradesToday=%d\n", s.tradesToday));
   FileWriteString(h, StringFormat("lossesToday=%d\n", s.lossesToday));
   FileWriteString(h, StringFormat("dayLocked=%d\n", (int)s.dayLocked));
   FileWriteString(h, StringFormat("accountLocked=%d\n", (int)s.accountLocked));
   FileWriteString(h, StringFormat("paused=%d\n", (int)s.paused));
   FileClose(h);
   return true;
  }

bool LoadState(GuardState &s)
  {
   if(!FileIsExist(StateFileName()))
      return false;
   int h = FileOpen(StateFileName(), FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return false;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      int eq = StringFind(line, "=");
      if(eq <= 0)
         continue;
      string k = StringSubstr(line, 0, eq);
      string v = StringSubstr(line, eq + 1);
      if(k == "dayKey")              s.dayKey = StringToInteger(v);
      else if(k == "dayAnchor")      s.dayAnchor = StringToDouble(v);
      else if(k == "initialBalance") s.initialBalance = StringToDouble(v);
      else if(k == "peakBalance")    s.peakBalance = StringToDouble(v);
      else if(k == "dayLowEquity")   s.dayLowEquity = StringToDouble(v);
      else if(k == "tradesToday")    s.tradesToday = (int)StringToInteger(v);
      else if(k == "lossesToday")    s.lossesToday = (int)StringToInteger(v);
      else if(k == "dayLocked")      s.dayLocked = (StringToInteger(v) != 0);
      else if(k == "accountLocked")  s.accountLocked = (StringToInteger(v) != 0);
      else if(k == "paused")         s.paused = (StringToInteger(v) != 0);
     }
   FileClose(h);
   return true;
  }
//+------------------------------------------------------------------+
#endif
