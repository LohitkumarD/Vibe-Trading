//+------------------------------------------------------------------+
//| PropGuardEA.mq5                                                  |
//| Prop-firm safe Expert Advisor: risk engine + London breakout.    |
//| Attach to ONE chart only (any symbol, any timeframe); it trades  |
//| every symbol listed in "Symbols".                                |
//+------------------------------------------------------------------+
#property copyright "Vibe Trading"
#property version   "1.10"
#property description "Prop-firm risk guard + strategies A (London breakout), B (trend pullback), D (SMC structure). Demo-test first."

#include <PropGuard/RiskGuard.mqh>
#include <PropGuard/Executor.mqh>
#include <PropGuard/NewsFilter.mqh>
#include <PropGuard/Strategies/LondonBreakout.mqh>
#include <PropGuard/Strategies/TrendPullback.mqh>
#include <PropGuard/Strategies/SmcStructure.mqh>

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

input group "Which strategies"
input string InpSymbols        = "EURUSD,GBPUSD"; // Symbols (comma separated, as in Market Watch)
input bool   InpUseA           = false; // A: London breakout
input bool   InpUseB           = true;  // B: H4/H1 trend pullback
input bool   InpUseD           = true;  // D: SMC structure (BOS/CHoCH + Order Block)

input group "Strategy A: London breakout (server time)"
input int    InpRangeStartHour = 3;    // Asian range start hour
input int    InpRangeEndHour   = 10;   // Asian range end hour = London open
input int    InpTradeEndHour   = 13;   // No new entries from this hour
input int    InpExitHour       = 22;   // Close open trades at this hour
input double InpMinRangeAtr    = 0.25; // Min range size x ATR(D1)
input double InpMaxRangeAtr    = 0.90; // Max range size x ATR(D1)
input double InpBufferFrac     = 0.10; // Breakout buffer, fraction of range
input double InpRR             = 1.5;  // Target in R
input bool   InpTrendFilter    = true; // Only trade breakouts with the H4 EMA200 trend

input group "Strategy B: trend pullback"
input double InpTpRR           = 2.0;  // Target in R
input int    InpTpStartHour    = 9;    // Entries from this server hour
input int    InpTpEndHour      = 20;   // No entries from this server hour
input int    InpTpMaxHoldHours = 72;   // Time stop (hours)

input group "Strategy D: SMC structure"
input ENUM_TIMEFRAMES InpSmcTf = PERIOD_H1; // Timeframe
input int    InpSmcSwing       = 2;    // Swing length N
input bool   InpSmcCloseConfirm = true; // Break confirmed by close (false = wick)
input int    InpSmcSignal      = 0;    // 0 both, 1 BOS only, 2 CHoCH only
input double InpSmcAtrFilter   = 0.8;  // Displacement body >= x ATR
input bool   InpSmcUseOB       = true; // Zone: true Order Block, false FVG
input bool   InpSmcWickBounds  = false; // OB bounds: true wick, false body
input double InpSmcFvgMinAtr   = 0.0;  // FVG min size x ATR
input int    InpSmcMaxRetrace  = 10;   // Limit order valid for N bars
input double InpSmcStopBufAtr  = 0.1;  // Stop buffer x ATR
input double InpSmcRR          = 2.0;  // Min R:R (and fallback target)
input int    InpSmcMaxBars     = 20;   // Time stop (bars)
input int    InpSmcStartHour   = 9;    // Signals from this server hour
input int    InpSmcEndHour     = 20;   // No signals from this server hour

input group "Technical"
input long   InpMagic          = 26112101; // Magic number
input int    InpDeviationPts   = 10;   // Max slippage (points)
input int    InpServerGmtWinter = 2;   // Tester only: server GMT offset in winter
input bool   InpServerUsesUsDst = true; // Tester only: server shifts with US DST
input bool   InpResearchMode   = true; // Tester only: after a pass/fail start a new challenge instead of stopping

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
   Comment("PropGuard v1.10\n", GuardStatus());
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
   gc.researchMode = InpResearchMode;
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
   lc.trendFilter = InpTrendFilter;
   if(InpUseA && !LbInit(lc, g_syms))
      return INIT_FAILED;

   TpConfig tc;
   tc.rr = InpTpRR;
   tc.startHour = InpTpStartHour;
   tc.endHour = InpTpEndHour;
   tc.maxHoldHours = InpTpMaxHoldHours;
   if(InpUseB && !TpInit(tc, g_syms))
      return INIT_FAILED;

   SmcConfig sc;
   sc.tf = InpSmcTf;
   sc.swingLen = InpSmcSwing;
   sc.closeConfirm = InpSmcCloseConfirm;
   sc.signalType = InpSmcSignal;
   sc.atrFilter = InpSmcAtrFilter;
   sc.atrPeriod = 14;
   sc.useOB = InpSmcUseOB;
   sc.wickBounds = InpSmcWickBounds;
   sc.fvgMinAtr = InpSmcFvgMinAtr;
   sc.maxRetraceBars = InpSmcMaxRetrace;
   sc.stopBufferAtr = InpSmcStopBufAtr;
   sc.rr = InpSmcRR;
   sc.maxBars = InpSmcMaxBars;
   sc.startHour = InpSmcStartHour;
   sc.endHour = InpSmcEndHour;
   if(InpUseD && !SmcInit(sc, g_syms))
      return INIT_FAILED;

   if(!InpUseA && !InpUseB && !InpUseD)
     {
      Print("PropGuard: turn on at least one strategy");
      return INIT_PARAMETERS_INCORRECT;
     }

   EventSetTimer(1);
   GuardUpdate();
   DrawPanel();
   Notify("started on " + AccountInfoString(ACCOUNT_SERVER) + ", symbols " + InpSymbols);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(InpUseA) LbDeinit();
   if(InpUseB) TpDeinit();
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
      // Each check also runs that strategy's housekeeping (time stops, expiry)
      TradeSignal s;
      if(InpUseD && SmcCheck(i, InpMagic, s))
         TrySignal(s, g_syms[i], active);
      if(InpUseB && TpCheck(i, InpMagic, s))
         TrySignal(s, g_syms[i], active);
      if(InpUseA && LbCheck(i, InpMagic, s))
         TrySignal(s, g_syms[i], active);
     }
   DrawPanel();
  }

void TrySignal(const TradeSignal &s, string sym, bool active)
  {
   if(!active || !s.valid)
      return;
   if(SymbolBusy(sym, InpMagic))
      return;
   string why = "";
   if(NewsBlocks(sym, InpNewsWindowMin, why))
     {
      Notify("skip " + s.tag + ": news " + why, false);
      return;
     }
   ExecuteSignal(s, sym, InpRiskPct, InpMaxLots, InpMaxSpreadPts, InpMagic, InpDeviationPts);
  }

double OnTester()
  {
   Print("PropGuard research summary\n", GuardResearchSummary());
   return GuardResearchScore();
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
