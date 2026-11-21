//+------------------------------------------------------------------+
//| PropGuardEA.mq5                                                  |
//| Prop-firm safe Expert Advisor: risk engine + London breakout.    |
//| Attach to ONE chart only (any symbol, any timeframe); it trades  |
//| every symbol listed in "Symbols".                                |
//+------------------------------------------------------------------+
#property copyright "Vibe Trading"
#property version   "1.00"
#property description "Prop-firm risk guard + London breakout (Strategy A). Demo-test first."

#include <PropGuard/RiskGuard.mqh>
#include <PropGuard/Executor.mqh>
#include <PropGuard/NewsFilter.mqh>
#include <PropGuard/Strategies/LondonBreakout.mqh>

//--- Prop firm
input group "Prop firm rules (verify on the firm's site!)"
input ENUM_PROP_FIRM   InpFirm            = FIRM_FUNDEDNEXT_2STEP; // Firm / challenge preset
input double           InpInitialBalance  = 0;     // Account starting balance (0 = current balance on first run)
input double           InpCustomDailyPct  = 5.0;   // Custom: daily loss %
input double           InpCustomMaxPct    = 10.0;  // Custom: max loss %
input bool             InpCustomTrailing  = false; // Custom: max loss trails the balance peak
input ENUM_DAILY_BASIS InpCustomBasis     = BASIS_MAX_BAL_EQ; // Custom: daily loss counted from
input ENUM_RESET_CLOCK InpCustomReset     = RESET_CET_MIDNIGHT; // Custom: daily reset clock
input double           InpCustomTargetPct = 10.0;  // Custom: profit target % (0 = funded)

input group "Safety buffers"
input double InpDailyUseFrac   = 0.60; // Stop at this share of the firm's DAILY limit
input double InpMaxUseFrac     = 0.70; // Stop at this share of the firm's MAX limit
input double InpRiskPct        = 0.40; // Risk per trade, % of starting balance
input double InpMaxLots        = 5.0;  // Hard cap on lots per trade
input int    InpMaxTradesDay   = 3;    // Max new trades per day
input int    InpMaxLossesDay   = 2;    // Stop for the day after this many losses
input int    InpNoEntryBeforeResetMin = 30; // No entries this close to the daily reset (min)
input int    InpNewsWindowMin  = 15;   // No entries +/- minutes around high-impact news (0 = off)
input int    InpFridayFlatHour = 21;   // Close all & stop on Friday from this server hour (24 = never)
input double InpMaxSpreadPts   = 25;   // Skip if spread is above this (points)
input bool   InpFlattenWholeAccount = true; // On a breach close ALL positions, not just the EA's
input bool   InpClearMaxLossLock = false;   // Set true once to clear a max-loss lock

input group "Strategy A: London breakout (server time)"
input string InpSymbols        = "EURUSD,GBPUSD"; // Symbols (comma separated, as in Market Watch)
input int    InpRangeStartHour = 3;    // Asian range start hour
input int    InpRangeEndHour   = 10;   // Asian range end hour = London open
input int    InpTradeEndHour   = 13;   // No new entries from this hour
input int    InpExitHour       = 22;   // Close open trades at this hour
input double InpMinRangeAtr    = 0.25; // Min range size x ATR(D1)
input double InpMaxRangeAtr    = 0.90; // Max range size x ATR(D1)
input double InpBufferFrac     = 0.10; // Breakout buffer, fraction of range
input double InpRR             = 1.5;  // Target in R

input group "Technical"
input long   InpMagic          = 26112101; // Magic number
input int    InpDeviationPts   = 10;   // Max slippage (points)
input int    InpServerGmtWinter = 2;   // Tester only: server GMT offset in winter
input bool   InpServerUsesUsDst = true; // Tester only: server shifts with US DST

string g_syms[];
const string BTN_PAUSE = "PG_btn_pause";
const string BTN_FLAT  = "PG_btn_flat";

//+------------------------------------------------------------------+
void MakeButton(string name, string text, int x, int y, color bg)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 140);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 28);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
  }

void DrawPanel()
  {
   MakeButton(BTN_PAUSE, GuardPaused() ? "RESUME" : "PAUSE", 150, 30,
              GuardPaused() ? clrSeaGreen : clrDarkOrange);
   MakeButton(BTN_FLAT, "CLOSE ALL + PAUSE", 150, 64, clrFireBrick);
   Comment("PropGuard v1.00\n", GuardStatus());
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);
   ArrayResize(g_syms, 0);
   for(int i = 0; i < n; i++)
     {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s == "")
         continue;
      if(!SymbolSelect(s, true))
        {
         PrintFormat("PropGuard: symbol %s not found. Use the exact name from Market Watch (e.g. EURUSD.r).", s);
         return INIT_PARAMETERS_INCORRECT;
        }
      int k = ArraySize(g_syms);
      ArrayResize(g_syms, k + 1);
      g_syms[k] = s;
     }
   if(ArraySize(g_syms) == 0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpRiskPct <= 0 || InpRiskPct > 1.0)
     {
      Print("PropGuard: risk per trade must be between 0 and 1%");
      return INIT_PARAMETERS_INCORRECT;
     }

   GuardConfig gc;
   LoadRuleProfile(InpFirm, gc.rules, InpCustomDailyPct, InpCustomMaxPct, InpCustomTrailing,
                   InpCustomBasis, InpCustomReset, InpCustomTargetPct);
   gc.dailyUseFrac = MathMax(0.1, MathMin(0.9, InpDailyUseFrac));
   gc.maxUseFrac = MathMax(0.1, MathMin(0.9, InpMaxUseFrac));
   gc.maxTradesPerDay = InpMaxTradesDay;
   gc.maxLossesPerDay = InpMaxLossesDay;
   gc.noEntryBeforeResetMin = InpNoEntryBeforeResetMin;
   gc.initialBalance = InpInitialBalance;
   gc.serverGmtOffsetWinter = InpServerGmtWinter;
   gc.serverUsesUsDst = InpServerUsesUsDst;
   gc.flattenWholeAccount = InpFlattenWholeAccount;
   gc.magic = InpMagic;
   if(!GuardInit(gc))
      return INIT_FAILED;
   if(InpClearMaxLossLock)
      GuardResetAccountLock();

   LbConfig lc;
   lc.rangeStartHour = InpRangeStartHour;
   lc.rangeEndHour = InpRangeEndHour;
   lc.tradeEndHour = InpTradeEndHour;
   lc.exitHour = InpExitHour;
   lc.minRangeAtr = InpMinRangeAtr;
   lc.maxRangeAtr = InpMaxRangeAtr;
   lc.bufferFrac = InpBufferFrac;
   lc.rr = InpRR;
   if(!LbInit(lc, g_syms))
      return INIT_FAILED;

   EventSetTimer(1);
   GuardUpdate();
   DrawPanel();
   Notify("started on " + AccountInfoString(ACCOUNT_SERVER) + ", symbols " + InpSymbols);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   LbDeinit();
   ObjectDelete(0, BTN_PAUSE);
   ObjectDelete(0, BTN_FLAT);
   Comment("");
   if(reason != REASON_CHARTCHANGE && reason != REASON_PARAMETERS)
      Notify("EA stopped (reason " + IntegerToString(reason) + ")");
  }

//+------------------------------------------------------------------+
bool FridayFlat()
  {
   if(InpFridayFlatHour >= 24)
      return false;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return t.day_of_week == 5 && t.hour >= InpFridayFlatHour;
  }

void RunOnce()
  {
   bool active = GuardUpdate();

   if(FridayFlat())
     {
      for(int i = 0; i < ArraySize(g_syms); i++)
         if(CountOwnPositions(g_syms[i], InpMagic) > 0)
            CloseOwnPositions(g_syms[i], InpMagic, "Friday flat before weekend");
      active = false;
     }

   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      TradeSignal s;
      LbCheck(i, InpMagic, s);   // also runs the time stop
      if(!active || !s.valid)
         continue;
      string why = "";
      if(NewsBlocks(g_syms[i], InpNewsWindowMin, why))
        {
         Notify("skip " + s.tag + ": news " + why, false);
         continue;
        }
      ExecuteSignal(s, g_syms[i], InpRiskPct, InpMaxLots, InpMaxSpreadPts, InpMagic, InpDeviationPts);
     }
   DrawPanel();
  }

void OnTick()  { RunOnce(); }
void OnTimer() { RunOnce(); }

//+------------------------------------------------------------------+
bool IsOurSymbol(string sym)
  {
   for(int i = 0; i < ArraySize(g_syms); i++)
      if(g_syms[i] == sym)
         return true;
   return false;
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   long entry  = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   long magic  = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   string sym  = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   double net  = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
               + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
               + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   bool manual = (reason == DEAL_REASON_CLIENT || reason == DEAL_REASON_MOBILE || reason == DEAL_REASON_WEB);
   if(magic == InpMagic || (manual && IsOurSymbol(sym)))
     {
      GuardOnExit(net);
      Notify(StringFormat("closed %s, result %.2f", sym, net));
     }
   // You closed a trade by hand (phone/PC/web): respect that and stop for today.
   if(manual && IsOurSymbol(sym) && !GuardPaused())
      GuardSetPaused(true, "manual close detected on " + sym + ", paused until the next daily reset");
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   if(sparam == BTN_PAUSE)
      GuardSetPaused(!GuardPaused(), "panel button");
   else if(sparam == BTN_FLAT)
     {
      FlattenAll("panel button");
      GuardSetPaused(true, "after CLOSE ALL");
     }
   DrawPanel();
  }
//+------------------------------------------------------------------+
