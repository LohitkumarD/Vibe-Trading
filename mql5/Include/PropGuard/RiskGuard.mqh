#ifndef PG_RISKGUARD
#define PG_RISKGUARD
//+------------------------------------------------------------------+
//| RiskGuard.mqh - the prop-firm safety engine                      |
//|                                                                  |
//| - Daily loss and max loss are measured on EQUITY, all the time,  |
//|   with floating P/L included (this is how firms measure it).     |
//| - We stop well before the firm's line (internal buffer).         |
//| - New trades are vetoed if equity, minus the loss to every open  |
//|   stop-loss, minus the new trade's risk, would cross our line.   |
//| - On a breach: close everything, delete pending orders, lock.    |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
#include "RuleProfile.mqh"
#include "StateStore.mqh"
#include "Notifier.mqh"

struct GuardConfig
  {
   RuleProfile       rules;
   double            dailyUseFrac;        // 0.6 = stop at 60% of firm daily limit
   double            maxUseFrac;          // 0.7 = stop at 70% of firm max limit
   int               maxTradesPerDay;
   int               maxLossesPerDay;
   int               noEntryBeforeResetMin;
   double            initialBalance;      // 0 = take balance on first run
   int               serverGmtOffsetWinter; // only used in Strategy Tester
   bool              serverUsesUsDst;       // only used in Strategy Tester
   bool              flattenWholeAccount;   // on breach close ALL positions, not just ours
   bool              researchMode;          // tester only: count challenges instead of locking
   long              magic;
  };

//--- Research mode counters (Strategy Tester only)
int    g_chPassed = 0;
int    g_chFailed = 0;
int    g_chDayLocks = 0;
datetime g_chStart = 0;
string g_chLog = "";

bool ResearchOn() { return g_cfg.researchMode && MQLInfoInteger(MQL_TESTER); }

//--- Treat the current balance as a brand-new challenge account
void StartNewChallenge(string why)
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_chLog += StringFormat("%s %s at balance %.2f\n", TimeToString(TimeCurrent(), TIME_DATE), why, bal);
   PrintFormat("PropGuard research: %s. New challenge starts at %.2f", why, bal);
   g_st.initialBalance = bal;
   g_st.peakBalance = bal;
   g_st.dayAnchor = MathMax(bal, AccountInfoDouble(ACCOUNT_EQUITY));
   g_st.accountLocked = false;
   g_chStart = TimeCurrent();
  }

GuardConfig g_cfg;
GuardState  g_st;
CTrade      g_guardTrade;
string      g_guardStatus = "";

//==================================================================
// Time helpers
//==================================================================
datetime MakeDate(int y, int m, int d, int hh = 0, int mm = 0)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year = y; t.mon = m; t.day = d; t.hour = hh; t.min = mm; t.sec = 0;
   return StructToTime(t);
  }

// n-th Sunday (n>=1) of a month, or the last Sunday when n == 0
datetime SundayOf(int y, int m, int n)
  {
   if(n == 0)
     {
      int nm = (m == 12) ? 1 : m + 1;
      int ny = (m == 12) ? y + 1 : y;
      datetime d = MakeDate(ny, nm, 1) - 86400;
      MqlDateTime t; TimeToStruct(d, t);
      return d - t.day_of_week * 86400;
     }
   datetime first = MakeDate(y, m, 1);
   MqlDateTime t; TimeToStruct(first, t);
   int add = (7 - t.day_of_week) % 7;
   return first + (add + 7 * (n - 1)) * 86400;
  }

bool IsEuDst(datetime gmt)
  {
   MqlDateTime t; TimeToStruct(gmt, t);
   datetime start = SundayOf(t.year, 3, 0) + 3600;   // last Sun Mar 01:00 UTC
   datetime end   = SundayOf(t.year, 10, 0) + 3600;  // last Sun Oct 01:00 UTC
   return gmt >= start && gmt < end;
  }

bool IsUsDst(datetime gmt)
  {
   MqlDateTime t; TimeToStruct(gmt, t);
   datetime start = SundayOf(t.year, 3, 2) + 7 * 3600;  // 2nd Sun Mar ~07:00 UTC
   datetime end   = SundayOf(t.year, 11, 1) + 6 * 3600; // 1st Sun Nov ~06:00 UTC
   return gmt >= start && gmt < end;
  }

datetime NowGmt()
  {
   if(!MQLInfoInteger(MQL_TESTER))
      return TimeGMT();
   // Tester: TimeGMT() is not reliable, derive it from the server clock.
   datetime srv = TimeCurrent();
   int off = g_cfg.serverGmtOffsetWinter;
   if(g_cfg.serverUsesUsDst && IsUsDst(srv - off * 3600))
      off += 1;
   return srv - off * 3600;
  }

// "Now" on the clock the firm uses for its daily reset
datetime FirmClockNow()
  {
   if(g_cfg.rules.resetClock == RESET_SERVER_MIDNIGHT)
      return MQLInfoInteger(MQL_TESTER) ? TimeCurrent() : TimeTradeServer();
   datetime gmt = NowGmt();
   return gmt + (IsEuDst(gmt) ? 2 : 1) * 3600;   // CET / CEST
  }

long DayKeyOf(datetime t)
  {
   MqlDateTime s; TimeToStruct(t, s);
   return (long)s.year * 10000 + s.mon * 100 + s.day;
  }

int MinutesToReset()
  {
   MqlDateTime s; TimeToStruct(FirmClockNow(), s);
   int secOfDay = s.hour * 3600 + s.min * 60 + s.sec;
   return (86400 - secOfDay) / 60;
  }

//==================================================================
// Limits (all in account currency)
//==================================================================
double DailyLimitMoney() { return g_st.initialBalance * g_cfg.rules.dailyLossPct / 100.0; }
double MaxLimitMoney()   { return g_st.initialBalance * g_cfg.rules.maxLossPct / 100.0; }

double FirmDailyFloor()  { return g_st.dayAnchor - DailyLimitMoney(); }
double OwnDailyFloor()   { return g_st.dayAnchor - DailyLimitMoney() * g_cfg.dailyUseFrac; }

double MaxLossRef()
  {
   if(!g_cfg.rules.maxLossTrailing)
      return g_st.initialBalance;
   return g_st.peakBalance;
  }
double FirmMaxFloor()
  {
   double f = MaxLossRef() - MaxLimitMoney();
   // Typical trailing rule: stops trailing once it reaches the initial balance
   if(g_cfg.rules.maxLossTrailing)
      f = MathMin(f, g_st.initialBalance);
   return f;
  }
double OwnMaxFloor()
  {
   double f = MaxLossRef() - MaxLimitMoney() * g_cfg.maxUseFrac;
   if(g_cfg.rules.maxLossTrailing)
      f = MathMin(f, g_st.initialBalance);
   return f;
  }

double OwnFloor() { return MathMax(OwnDailyFloor(), OwnMaxFloor()); }

//--- Money lost if every open position hits its stop-loss (positive number).
//--- Returns -1 when a position has no stop-loss (risk unknown).
double OpenRiskToStops()
  {
   double risk = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      double sl  = PositionGetDouble(POSITION_SL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double cur = PositionGetDouble(POSITION_PRICE_CURRENT);
      long   typ = PositionGetInteger(POSITION_TYPE);
      if(sl <= 0.0)
         return -1.0;
      double p = 0.0;
      ENUM_ORDER_TYPE ot = (typ == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcProfit(ot, sym, vol, cur, sl, p))
         return -1.0;
      if(p < 0.0)
         risk += -p;
     }
   // Pending orders count too: they can fill at any moment.
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      long typ = OrderGetInteger(ORDER_TYPE);
      if(typ != ORDER_TYPE_BUY_LIMIT && typ != ORDER_TYPE_SELL_LIMIT &&
         typ != ORDER_TYPE_BUY_STOP && typ != ORDER_TYPE_SELL_STOP)
         continue;
      string sym = OrderGetString(ORDER_SYMBOL);
      double sl  = OrderGetDouble(ORDER_SL);
      double vol = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double px  = OrderGetDouble(ORDER_PRICE_OPEN);
      if(sl <= 0.0)
         return -1.0;
      double p = 0.0;
      bool buy = (typ == ORDER_TYPE_BUY_LIMIT || typ == ORDER_TYPE_BUY_STOP);
      if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, vol, px, sl, p))
         return -1.0;
      if(p < 0.0)
         risk += -p;
     }
   return risk;
  }

//==================================================================
// Actions
//==================================================================
void FlattenAll(string why)
  {
   g_guardTrade.SetExpertMagicNumber(g_cfg.magic);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!g_cfg.flattenWholeAccount && PositionGetInteger(POSITION_MAGIC) != g_cfg.magic)
         continue;
      g_guardTrade.PositionClose(ticket);
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!g_cfg.flattenWholeAccount && OrderGetInteger(ORDER_MAGIC) != g_cfg.magic)
         continue;
      g_guardTrade.OrderDelete(ticket);
     }
   Notify("FLATTENED: " + why);
  }

void StartNewDay(long key)
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_st.dayKey = key;
   g_st.dayAnchor = (g_cfg.rules.dailyBasis == BASIS_MAX_BAL_EQ) ? MathMax(bal, eq) : bal;
   g_st.dayLowEquity = eq;
   g_st.tradesToday = 0;
   g_st.lossesToday = 0;
   g_st.dayLocked = false;
   g_st.paused = false;            // a manual pause lasts until the next reset
   SaveState(g_st);
   PrintFormat("PropGuard: new trading day %I64d, anchor %.2f, own floor %.2f, firm floor %.2f",
               key, g_st.dayAnchor, OwnDailyFloor(), FirmDailyFloor());
  }

//==================================================================
// Public API
//==================================================================
bool GuardInit(const GuardConfig &cfg)
  {
   g_cfg = cfg;
   g_guardTrade.SetExpertMagicNumber(cfg.magic);
   ZeroMemory(g_st);
   bool had = LoadState(g_st);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(cfg.initialBalance > 0.0)
      g_st.initialBalance = cfg.initialBalance;
   else if(!had || g_st.initialBalance <= 0.0)
      g_st.initialBalance = bal;
   if(g_st.peakBalance < bal)
      g_st.peakBalance = bal;
   if(g_st.peakBalance < g_st.initialBalance)
      g_st.peakBalance = g_st.initialBalance;
   long key = DayKeyOf(FirmClockNow());
   if(MQLInfoInteger(MQL_TESTER))
     {
      // Every tester run starts clean.
      ZeroMemory(g_st);
      g_st.initialBalance = (cfg.initialBalance > 0.0) ? cfg.initialBalance : bal;
      g_st.peakBalance = MathMax(bal, g_st.initialBalance);
      had = false;
     }
   g_chStart = TimeCurrent();
   if(!had || g_st.dayKey != key)
      StartNewDay(key);
   SaveState(g_st);
   PrintFormat("PropGuard: %s, initial %.2f, daily %.1f%% (we stop at %.0f%% of it), max %.1f%% (we stop at %.0f%%)",
               cfg.rules.name, g_st.initialBalance, cfg.rules.dailyLossPct, cfg.dailyUseFrac * 100,
               cfg.rules.maxLossPct, cfg.maxUseFrac * 100);
   return true;
  }

//--- Call on every tick and timer. Returns false if trading is not allowed.
bool GuardUpdate()
  {
   long key = DayKeyOf(FirmClockNow());
   if(key != g_st.dayKey)
      StartNewDay(key);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(PositionsTotal() == 0 && bal > g_st.peakBalance)
     {
      g_st.peakBalance = bal;
      SaveState(g_st);
     }
   if(eq < g_st.dayLowEquity)
      g_st.dayLowEquity = eq;

   if(ResearchOn() && g_cfg.rules.profitTargetPct > 0 && PositionsTotal() == 0 &&
      bal >= g_st.initialBalance * (1.0 + g_cfg.rules.profitTargetPct / 100.0))
     {
      g_chPassed++;
      StartNewChallenge(StringFormat("PASSED (+%.1f%% in %d days)", g_cfg.rules.profitTargetPct,
                                     (int)((TimeCurrent() - g_chStart) / 86400)));
     }

   if(!g_st.accountLocked && eq <= OwnMaxFloor())
     {
      g_st.accountLocked = true;
      SaveState(g_st);
      FlattenAll(StringFormat("max-loss guard hit, equity %.2f <= %.2f. EA locked until you reset it.", eq, OwnMaxFloor()));
      if(ResearchOn())
        {
         g_chFailed++;
         StartNewChallenge("FAILED (max-loss guard)");
        }
     }
   else if(!g_st.dayLocked && eq <= OwnDailyFloor())
     {
      g_st.dayLocked = true;
      g_chDayLocks++;
      SaveState(g_st);
      FlattenAll(StringFormat("daily guard hit, equity %.2f <= %.2f. Done until the next reset.", eq, OwnDailyFloor()));
     }

   g_guardStatus = StringFormat(
      "%s | equity %.2f | today's floor %.2f (firm %.2f) | max floor %.2f (firm %.2f)\n"
      "trades %d/%d, losses %d/%d | reset in %d min | %s",
      g_cfg.rules.name, eq, OwnDailyFloor(), FirmDailyFloor(), OwnMaxFloor(), FirmMaxFloor(),
      g_st.tradesToday, g_cfg.maxTradesPerDay, g_st.lossesToday, g_cfg.maxLossesPerDay,
      MinutesToReset(),
      g_st.accountLocked ? "LOCKED (max loss)" : g_st.dayLocked ? "DONE FOR TODAY" :
      g_st.paused ? "PAUSED" : "ACTIVE");

   return !(g_st.accountLocked || g_st.dayLocked || g_st.paused);
  }

//--- May we open a new trade that risks `riskMoney` if its stop is hit?
bool GuardCanOpen(double riskMoney, string &reason)
  {
   if(!GuardUpdate())
     { reason = "guard not active"; return false; }
   if(g_st.tradesToday >= g_cfg.maxTradesPerDay)
     { reason = "max trades for today reached"; return false; }
   if(g_st.lossesToday >= g_cfg.maxLossesPerDay)
     { reason = "max losing trades for today reached"; return false; }
   if(MinutesToReset() <= g_cfg.noEntryBeforeResetMin)
     { reason = "too close to the daily reset"; return false; }
   double open = OpenRiskToStops();
   if(open < 0.0)
     { reason = "an open position has no stop-loss"; return false; }
   double worst = AccountInfoDouble(ACCOUNT_EQUITY) - open - riskMoney;
   if(worst <= OwnFloor())
     {
      reason = StringFormat("worst case %.2f would cross our floor %.2f", worst, OwnFloor());
      return false;
     }
   return true;
  }

void GuardOnEntry()
  {
   g_st.tradesToday++;
   SaveState(g_st);
  }

void GuardOnExit(double netProfit)
  {
   if(netProfit < 0.0)
      g_st.lossesToday++;
   SaveState(g_st);
  }

void GuardSetPaused(bool p, string why)
  {
   g_st.paused = p;
   SaveState(g_st);
   Notify(p ? "PAUSED: " + why : "RESUMED: " + why);
  }

bool GuardPaused() { return g_st.paused; }

void GuardResetAccountLock()
  {
   g_st.accountLocked = false;
   SaveState(g_st);
   Notify("max-loss lock cleared by user");
  }

double GuardInitialBalance() { return g_st.initialBalance; }

string GuardResearchSummary()
  {
   return StringFormat("Challenges passed: %d, failed: %d, days stopped by daily guard: %d\n%s",
                       g_chPassed, g_chFailed, g_chDayLocks, g_chLog);
  }
double GuardResearchScore() { return g_chPassed - g_chFailed; }
string GuardStatus()         { return g_guardStatus; }
//+------------------------------------------------------------------+
#endif
