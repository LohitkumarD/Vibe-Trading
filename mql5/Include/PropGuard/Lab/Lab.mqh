#ifndef PG_LAB
#define PG_LAB
//+------------------------------------------------------------------+
//| Lab.mqh - learning layer for intraday M1/M5 strategies           |
//|                                                                  |
//| Every strategy has its own magic number (LabMagicBase + id).     |
//| Each signal becomes either a LIVE trade or a PAPER trade (tracked|
//| virtually with real bid/ask, spread and commission). Results are |
//| scored in R (1R = the money lost at the stop).                   |
//|                                                                  |
//| Modes, decided from the last LAB_WIN results (live + paper):     |
//|   PROBATION  live at small risk (new or unproven)                |
//|   ACTIVE     live at full lab risk (proven edge)                 |
//|   BENCHED    paper only (losing); comes back if paper improves   |
//|                                                                  |
//| State survives restarts: MQL5\Files\PropGuard_lab_<login>.txt    |
//| Trade log:  MQL5\Files\PropGuard_lab_trades_<login>.csv          |
//| Daily report: MQL5\Files\PropGuard_lab_report_<login>.txt + push |
//+------------------------------------------------------------------+
#include "../Executor.mqh"
#include "../NewsFilter.mqh"

#define LAB_N       7     // number of lab strategies
#define LAB_WIN     30    // results used for scoring
#define LAB_MAXSYM  12
#define LAB_PAPER   64
#define LAB_LIVE    32

enum ENUM_LAB_MODE
  {
   LAB_PROBATION = 0,
   LAB_ACTIVE    = 1,
   LAB_BENCHED   = 2,
   LAB_OFF       = 3
  };

struct LabConfig
  {
   string            enabled;        // "1111111", one char per strategy
   double            riskProbation;  // % per trade
   double            riskActive;     // % per trade
   int               minTrades;      // results needed before promote/bench
   double            promotePf;
   double            promoteExpR;
   double            benchPf;
   int               benchConsecLoss;
   int               maxOpen;        // live lab positions at once (all symbols)
   int               maxPerDay;      // signals per strategy per symbol per day
   double            commPerLot;     // round-turn commission per 1.0 lot (account ccy), paper trades
   double            minStopSpreads; // stop must be >= this many spreads
   double            maxLots;
   double            maxSpreadPts;
   long              magicBase;
   int               deviationPts;
   int               newsWindowMin;
  };

struct LabStat
  {
   int               mode;
   int               n;          // all results ever
   int               wins;
   double            sumR;
   int               liveN;
   double            liveSumR;
   double            liveMoney;
   int               consecLiveLoss;
   int               dayN;
   int               dayWins;
   double            daySumR;
   int               dayLiveN;
   double            dayMoney;
  };

struct LabPaperTrade
  {
   bool              used;
   int               strat;
   string            sym;
   int               dir;
   double            entry;
   double            sl;
   double            tp;
   datetime          opened;
   datetime          expires;
   double            commR;
  };

struct LabLiveTrade
  {
   bool              used;
   ulong             posId;
   int               strat;
   string            sym;
   int               dir;
   double            riskMoney;
   datetime          opened;
   datetime          expires;
  };

LabConfig     g_lab;
LabStat       g_labSt[LAB_N];
double        g_labRecent[LAB_N][LAB_WIN];
int           g_labRecentCount[LAB_N];
int           g_labRecentPos[LAB_N];
LabPaperTrade g_labPaper[LAB_PAPER];
LabLiveTrade  g_labLive[LAB_LIVE];
string        g_labSyms[];
int           g_labSigDay[LAB_N][LAB_MAXSYM];     // yyyymmdd of the last signal
int           g_labSigCount[LAB_N][LAB_MAXSYM];   // signals that day
datetime      g_labSigTime[LAB_N][LAB_MAXSYM];    // time of the last signal
long          g_labReportDay = 0;

string LabCode(int s)
  {
   switch(s)
     {
      case 0: return "L0 ORB-London";
      case 1: return "L1 ORB-NewYork";
      case 2: return "L2 VWAP-revert";
      case 3: return "L3 Asia-BB-RSI2";
      case 4: return "L4 EMA-pullback";
      case 5: return "L5 Asia-sweep";
      case 6: return "L6 M1-EMA-scalp";
     }
   return "L?";
  }

string LabModeName(int m)
  {
   switch(m)
     {
      case LAB_PROBATION: return "TRIAL";
      case LAB_ACTIVE:    return "ACTIVE";
      case LAB_BENCHED:   return "PAPER";
     }
   return "OFF";
  }

long LabMagic(int s) { return g_lab.magicBase + s; }

int LabStratOfMagic(long magic)
  {
   long d = magic - g_lab.magicBase;
   if(d < 0 || d >= LAB_N)
      return -1;
   return (int)d;
  }

bool LabIsMagic(long magic) { return LabStratOfMagic(magic) >= 0; }

long LabDayKey(datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return (long)d.year * 10000 + d.mon * 100 + d.day;
  }

string LabFile(string kind)
  {
   return StringFormat("PropGuard_lab%s_%I64d.%s", kind, AccountInfoInteger(ACCOUNT_LOGIN),
                       kind == "_trades" ? "csv" : "txt");
  }

//==================================================================
// Scoring
//==================================================================
void LabScore(int s, int &cnt, double &pf, double &expR, double &winRate)
  {
   cnt = g_labRecentCount[s];
   double gw = 0, gl = 0, sum = 0;
   int w = 0;
   for(int i = 0; i < cnt; i++)
     {
      double r = g_labRecent[s][i];
      sum += r;
      if(r > 0) { gw += r; w++; }
      else      gl += -r;
     }
   pf = (gl > 0) ? gw / gl : (gw > 0 ? 99.0 : 0.0);
   expR = (cnt > 0) ? sum / cnt : 0.0;
   winRate = (cnt > 0) ? 100.0 * w / cnt : 0.0;
  }

void LabSetMode(int s, int m, string why)
  {
   if(g_labSt[s].mode == m)
      return;
   string old = LabModeName(g_labSt[s].mode);
   g_labSt[s].mode = m;
   Notify(StringFormat("%s: %s -> %s (%s)", LabCode(s), old, LabModeName(m), why));
  }

void LabEvaluate(int s)
  {
   if(g_labSt[s].mode == LAB_OFF)
      return;
   int cnt; double pf, expR, wr;
   LabScore(s, cnt, pf, expR, wr);
   if(g_labSt[s].consecLiveLoss >= g_lab.benchConsecLoss && g_labSt[s].mode != LAB_BENCHED)
     {
      g_labSt[s].consecLiveLoss = 0;
      LabSetMode(s, LAB_BENCHED, StringFormat("%d live losses in a row", g_lab.benchConsecLoss));
      return;
     }
   if(cnt < g_lab.minTrades)
      return;
   string why = StringFormat("last %d: PF %.2f, %.2fR/trade, win %.0f%%", cnt, pf, expR, wr);
   bool good = (pf >= g_lab.promotePf && expR >= g_lab.promoteExpR);
   switch(g_labSt[s].mode)
     {
      case LAB_PROBATION:
         if(good)                     LabSetMode(s, LAB_ACTIVE, why);
         else if(pf < g_lab.benchPf)  LabSetMode(s, LAB_BENCHED, why);
         break;
      case LAB_ACTIVE:
         if(pf < 1.0)                 LabSetMode(s, LAB_PROBATION, why);
         break;
      case LAB_BENCHED:
         if(good)                     LabSetMode(s, LAB_PROBATION, why);
         break;
     }
  }

void LabLogTrade(int s, string sym, int dir, bool live, double r, double money, datetime opened)
  {
   int h = FileOpen(LabFile("_trades"), FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return;
   if(FileSize(h) == 0)
      FileWriteString(h, "closed,opened,strategy,symbol,side,type,result_R,money,mode\n");
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, StringFormat("%s,%s,%s,%s,%s,%s,%.3f,%.2f,%s\n",
                   TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
                   TimeToString(opened, TIME_DATE | TIME_MINUTES),
                   LabCode(s), sym, dir > 0 ? "BUY" : "SELL", live ? "LIVE" : "PAPER",
                   r, money, LabModeName(g_labSt[s].mode)));
   FileClose(h);
  }

void LabSaveState();

void LabRecord(int s, string sym, int dir, bool live, double r, double money, datetime opened)
  {
   int p = g_labRecentPos[s];
   g_labRecent[s][p] = r;
   g_labRecentPos[s] = (p + 1) % LAB_WIN;
   if(g_labRecentCount[s] < LAB_WIN)
      g_labRecentCount[s]++;
   // keep g_labRecent[s][0..count-1] meaningful: when not full, pos == count
   g_labSt[s].n++;
   g_labSt[s].sumR += r;
   g_labSt[s].dayN++;
   g_labSt[s].daySumR += r;
   if(r > 0) { g_labSt[s].wins++; g_labSt[s].dayWins++; }
   if(live)
     {
      g_labSt[s].liveN++;
      g_labSt[s].liveSumR += r;
      g_labSt[s].liveMoney += money;
      g_labSt[s].dayLiveN++;
      g_labSt[s].dayMoney += money;
      g_labSt[s].consecLiveLoss = (r < 0) ? g_labSt[s].consecLiveLoss + 1 : 0;
     }
   LabLogTrade(s, sym, dir, live, r, money, opened);
   LabEvaluate(s);
   LabSaveState();
  }

//==================================================================
// Persistence
//==================================================================
void LabSaveState()
  {
   if(MQLInfoInteger(MQL_TESTER))
      return;
   int h = FileOpen(LabFile(""), FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, StringFormat("reportDay=%I64d\n", g_labReportDay));
   for(int s = 0; s < LAB_N; s++)
     {
      LabStat st = g_labSt[s];
      FileWriteString(h, StringFormat("S|%d|%d|%d|%d|%.4f|%d|%.4f|%.2f|%d|%d|%d|%.4f|%d|%.2f\n",
                      s, st.mode, st.n, st.wins, st.sumR, st.liveN, st.liveSumR, st.liveMoney,
                      st.consecLiveLoss, st.dayN, st.dayWins, st.daySumR, st.dayLiveN, st.dayMoney));
      string r = "";
      // oldest first
      int cnt = g_labRecentCount[s];
      int start = (cnt < LAB_WIN) ? 0 : g_labRecentPos[s];
      for(int i = 0; i < cnt; i++)
         r += (i > 0 ? "," : "") + DoubleToString(g_labRecent[s][(start + i) % LAB_WIN], 3);
      FileWriteString(h, StringFormat("R|%d|%s\n", s, r));
     }
   for(int i = 0; i < LAB_PAPER; i++)
      if(g_labPaper[i].used)
        {
         LabPaperTrade p = g_labPaper[i];
         FileWriteString(h, StringFormat("P|%d|%s|%d|%.6f|%.6f|%.6f|%I64d|%I64d|%.4f\n",
                         p.strat, p.sym, p.dir, p.entry, p.sl, p.tp, (long)p.opened, (long)p.expires, p.commR));
        }
   for(int i = 0; i < LAB_LIVE; i++)
      if(g_labLive[i].used)
        {
         LabLiveTrade l = g_labLive[i];
         FileWriteString(h, StringFormat("O|%I64u|%d|%s|%d|%.2f|%I64d|%I64d\n",
                         l.posId, l.strat, l.sym, l.dir, l.riskMoney, (long)l.opened, (long)l.expires));
        }
   FileClose(h);
  }

void LabLoadState()
  {
   if(MQLInfoInteger(MQL_TESTER) || !FileIsExist(LabFile("")))
      return;
   int h = FileOpen(LabFile(""), FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;
   int np = 0, nl = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      if(StringFind(line, "reportDay=") == 0)
        {
         g_labReportDay = StringToInteger(StringSubstr(line, 10));
         continue;
        }
      string f[];
      int k = StringSplit(line, '|', f);
      if(k < 2)
         continue;
      if(f[0] == "S" && k >= 15)
        {
         int s = (int)StringToInteger(f[1]);
         if(s < 0 || s >= LAB_N) continue;
         int m = (int)StringToInteger(f[2]);
         if(m < LAB_PROBATION || m > LAB_BENCHED)
            m = LAB_PROBATION;
         if(g_labSt[s].mode != LAB_OFF)      // switched off by input wins
            g_labSt[s].mode = m;
         g_labSt[s].n = (int)StringToInteger(f[3]);
         g_labSt[s].wins = (int)StringToInteger(f[4]);
         g_labSt[s].sumR = StringToDouble(f[5]);
         g_labSt[s].liveN = (int)StringToInteger(f[6]);
         g_labSt[s].liveSumR = StringToDouble(f[7]);
         g_labSt[s].liveMoney = StringToDouble(f[8]);
         g_labSt[s].consecLiveLoss = (int)StringToInteger(f[9]);
         g_labSt[s].dayN = (int)StringToInteger(f[10]);
         g_labSt[s].dayWins = (int)StringToInteger(f[11]);
         g_labSt[s].daySumR = StringToDouble(f[12]);
         g_labSt[s].dayLiveN = (int)StringToInteger(f[13]);
         g_labSt[s].dayMoney = StringToDouble(f[14]);
        }
      else if(f[0] == "R")
        {
         int s = (int)StringToInteger(f[1]);
         if(s < 0 || s >= LAB_N || k < 3 || f[2] == "") continue;
         string v[];
         int c = StringSplit(f[2], ',', v);
         g_labRecentCount[s] = 0;
         g_labRecentPos[s] = 0;
         for(int i = 0; i < c && i < LAB_WIN; i++)
           {
            g_labRecent[s][i] = StringToDouble(v[i]);
            g_labRecentCount[s]++;
           }
         g_labRecentPos[s] = g_labRecentCount[s] % LAB_WIN;
        }
      else if(f[0] == "P" && k >= 10 && np < LAB_PAPER)
        {
         g_labPaper[np].used = true;
         g_labPaper[np].strat = (int)StringToInteger(f[1]);
         g_labPaper[np].sym = f[2];
         g_labPaper[np].dir = (int)StringToInteger(f[3]);
         g_labPaper[np].entry = StringToDouble(f[4]);
         g_labPaper[np].sl = StringToDouble(f[5]);
         g_labPaper[np].tp = StringToDouble(f[6]);
         g_labPaper[np].opened = (datetime)StringToInteger(f[7]);
         g_labPaper[np].expires = (datetime)StringToInteger(f[8]);
         g_labPaper[np].commR = StringToDouble(f[9]);
         np++;
        }
      else if(f[0] == "O" && k >= 8 && nl < LAB_LIVE)
        {
         g_labLive[nl].used = true;
         g_labLive[nl].posId = (ulong)StringToInteger(f[1]);
         g_labLive[nl].strat = (int)StringToInteger(f[2]);
         g_labLive[nl].sym = f[3];
         g_labLive[nl].dir = (int)StringToInteger(f[4]);
         g_labLive[nl].riskMoney = StringToDouble(f[5]);
         g_labLive[nl].opened = (datetime)StringToInteger(f[6]);
         g_labLive[nl].expires = (datetime)StringToInteger(f[7]);
         nl++;
        }
     }
   FileClose(h);
   PrintFormat("PropGuard Lab: state loaded (%d paper, %d live trades open)", np, nl);
  }

//==================================================================
// Init
//==================================================================
bool LabInitCore(const LabConfig &cfg, string &symbols[])
  {
   g_lab = cfg;
   int n = MathMin(ArraySize(symbols), LAB_MAXSYM);
   ArrayResize(g_labSyms, n);
   for(int i = 0; i < n; i++)
      g_labSyms[i] = symbols[i];
   for(int s = 0; s < LAB_N; s++)
     {
      ZeroMemory(g_labSt[s]);
      bool on = (StringLen(cfg.enabled) > s) ? (StringSubstr(cfg.enabled, s, 1) == "1") : true;
      g_labSt[s].mode = on ? LAB_PROBATION : LAB_OFF;
      g_labRecentCount[s] = 0;
      g_labRecentPos[s] = 0;
      for(int j = 0; j < LAB_MAXSYM; j++)
        { g_labSigDay[s][j] = 0; g_labSigCount[s][j] = 0; g_labSigTime[s][j] = 0; }
     }
   for(int i = 0; i < LAB_PAPER; i++) g_labPaper[i].used = false;
   for(int i = 0; i < LAB_LIVE; i++)  g_labLive[i].used = false;
   LabLoadState();
   if(g_labReportDay == 0)
      g_labReportDay = LabDayKey(TimeCurrent());
   return true;
  }

//==================================================================
// Signal limits
//==================================================================
bool LabSignalAllowed(int s, int symIdx, int minGapSec)
  {
   int day = (int)LabDayKey(TimeCurrent());
   if(g_labSigDay[s][symIdx] != day)
     {
      g_labSigDay[s][symIdx] = day;
      g_labSigCount[s][symIdx] = 0;
     }
   if(g_labSigCount[s][symIdx] >= g_lab.maxPerDay)
      return false;
   if(TimeCurrent() - g_labSigTime[s][symIdx] < minGapSec)
      return false;
   return true;
  }

void LabMarkSignal(int s, int symIdx)
  {
   g_labSigCount[s][symIdx]++;
   g_labSigTime[s][symIdx] = TimeCurrent();
  }

// Mark a "once per day" strategy as done for today on this symbol
void LabMarkDayDone(int s, int symIdx)
  {
   g_labSigDay[s][symIdx] = (int)LabDayKey(TimeCurrent());
   g_labSigCount[s][symIdx] = g_lab.maxPerDay;
  }

//==================================================================
// Live / paper bookkeeping
//==================================================================
int LabLiveOpenCount(string sym = "")
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(!LabIsMagic(PositionGetInteger(POSITION_MAGIC)))
         continue;
      if(sym == "" || PositionGetString(POSITION_SYMBOL) == sym)
         n++;
     }
   return n;
  }

bool LabSelectPositionById(ulong posId)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER) == posId)
         return true;
     }
   return false;
  }

double LabCommR(string sym, int dir, double entry, double sl)
  {
   if(g_lab.commPerLot <= 0)
      return 0.0;
   double loss = 0;
   if(!OrderCalcProfit(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, 1.0, entry, sl, loss))
      return 0.0;
   loss = MathAbs(loss);
   return (loss > 0) ? g_lab.commPerLot / loss : 0.0;
  }

void LabOpenPaper(int s, string sym, const TradeSignal &sig, int holdSec)
  {
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double entry = (sig.dir > 0) ? ask : bid;
   if((sig.dir > 0 && sig.sl >= entry) || (sig.dir < 0 && sig.sl <= entry))
      return;
   for(int i = 0; i < LAB_PAPER; i++)
      if(!g_labPaper[i].used)
        {
         g_labPaper[i].used = true;
         g_labPaper[i].strat = s;
         g_labPaper[i].sym = sym;
         g_labPaper[i].dir = sig.dir;
         g_labPaper[i].entry = entry;
         g_labPaper[i].sl = sig.sl;
         g_labPaper[i].tp = sig.tp;
         g_labPaper[i].opened = TimeCurrent();
         g_labPaper[i].expires = TimeCurrent() + holdSec;
         g_labPaper[i].commR = LabCommR(sym, sig.dir, entry, sig.sl);
         PrintFormat("PropGuard Lab: PAPER %s %s %s at %.5f SL %.5f TP %.5f", LabCode(s),
                     sig.dir > 0 ? "BUY" : "SELL", sym, entry, sig.sl, sig.tp);
         LabSaveState();
         return;
        }
  }

// Check paper trades against the live bid/ask (call every second)
void LabUpdatePaper()
  {
   for(int i = 0; i < LAB_PAPER; i++)
     {
      if(!g_labPaper[i].used)
         continue;
      LabPaperTrade p = g_labPaper[i];
      double bid = SymbolInfoDouble(p.sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(p.sym, SYMBOL_ASK);
      if(bid <= 0 || ask <= 0)
         continue;
      double px = (p.dir > 0) ? bid : ask;        // price we would exit at
      double risk = MathAbs(p.entry - p.sl);
      if(risk <= 0) { g_labPaper[i].used = false; continue; }
      double exitPx = 0;
      if(p.dir > 0)
        {
         if(px <= p.sl)                 exitPx = MathMin(px, p.sl);
         else if(p.tp > 0 && px >= p.tp) exitPx = p.tp;
        }
      else
        {
         if(px >= p.sl)                 exitPx = MathMax(px, p.sl);
         else if(p.tp > 0 && px <= p.tp) exitPx = p.tp;
        }
      if(exitPx == 0 && TimeCurrent() >= p.expires)
         exitPx = px;
      if(exitPx == 0)
         continue;
      double r = (exitPx - p.entry) * p.dir / risk - p.commR;
      g_labPaper[i].used = false;
      LabRecord(p.strat, p.sym, p.dir, false, r, 0.0, p.opened);
     }
  }

// Time stops for live lab positions
void LabUpdateLive()
  {
   for(int i = 0; i < LAB_LIVE; i++)
     {
      if(!g_labLive[i].used)
         continue;
      if(!LabSelectPositionById(g_labLive[i].posId))
        {
         // closed while we were not watching (e.g. restart) and never matched: drop after 1 day
         if(TimeCurrent() - g_labLive[i].opened > 86400 * 3)
            g_labLive[i].used = false;
         continue;
        }
      if(TimeCurrent() >= g_labLive[i].expires)
        {
         g_exec.SetExpertMagicNumber(LabMagic(g_labLive[i].strat));
         ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
         if(g_exec.PositionClose(ticket))
            Notify("closed " + g_labLive[i].sym + ": " + LabCode(g_labLive[i].strat) + " time stop");
        }
     }
  }

// Called from OnTradeTransaction for every closing deal of a lab magic
void LabOnExitDeal(ulong deal)
  {
   long magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
   int s = LabStratOfMagic(magic);
   if(s < 0)
      return;
   ulong posId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
   // Net money over every deal of this position (entry commission included)
   double net = 0;
   int dir = 0;
   if(HistorySelectByPosition(posId))
     {
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong d = HistoryDealGetTicket(i);
         net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
              + HistoryDealGetDouble(d, DEAL_COMMISSION);
         if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
            dir = (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY) ? 1 : -1;
        }
     }
   else
      net = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP)
          + HistoryDealGetDouble(deal, DEAL_COMMISSION);
   if(LabSelectPositionById(posId))
      return;                      // partial close: wait for the final one
   double risk = 0;
   datetime opened = TimeCurrent();
   for(int i = 0; i < LAB_LIVE; i++)
      if(g_labLive[i].used && g_labLive[i].posId == posId)
        {
         risk = g_labLive[i].riskMoney;
         opened = g_labLive[i].opened;
         if(dir == 0) dir = g_labLive[i].dir;
         g_labLive[i].used = false;
         break;
        }
   if(risk <= 0)
      risk = GuardInitialBalance() * g_lab.riskProbation / 100.0;
   double r = (risk > 0) ? net / risk : 0.0;
   LabRecord(s, sym, dir, true, r, net, opened);
   Notify(StringFormat("%s %s closed %.2f (%.2fR)", LabCode(s), sym, net, r));
  }

void LabCloseAll(string sym, string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!LabIsMagic(magic) || (sym != "" && PositionGetString(POSITION_SYMBOL) != sym))
         continue;
      g_exec.SetExpertMagicNumber(magic);
      if(g_exec.PositionClose(t))
         Notify("closed " + PositionGetString(POSITION_SYMBOL) + ": " + why);
     }
  }

//==================================================================
// Route a signal: live if allowed, otherwise paper
//==================================================================
void LabRoute(int s, int symIdx, TradeSignal &sig, int holdSec, bool guardActive)
  {
   if(!sig.valid || g_labSt[s].mode == LAB_OFF)
      return;
   string sym = g_labSyms[symIdx];
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double spread = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
   double ref = (sig.dir > 0) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   double stopDist = MathAbs(ref - sig.sl);
   if(g_lab.maxSpreadPts > 0 && spread / point > g_lab.maxSpreadPts)
      return;                                   // a real filter, not a learning case
   if(stopDist < g_lab.minStopSpreads * spread)
      return;                                   // costs would eat the trade
   string why = "";
   if(NewsBlocks(sym, g_lab.newsWindowMin, why))
      return;
   sig.tag = LabCode(s);
   LabMarkSignal(s, symIdx);

   bool live = guardActive && (g_labSt[s].mode == LAB_PROBATION || g_labSt[s].mode == LAB_ACTIVE)
               && LabLiveOpenCount() < g_lab.maxOpen && LabLiveOpenCount(sym) == 0;
   if(live)
     {
      double riskPct = (g_labSt[s].mode == LAB_ACTIVE) ? g_lab.riskActive : g_lab.riskProbation;
      if(ExecuteSignal(sig, sym, riskPct, g_lab.maxLots, g_lab.maxSpreadPts, LabMagic(s), g_lab.deviationPts))
        {
         ulong posId = g_exec.ResultOrder();
         double riskMoney = GuardInitialBalance() * riskPct / 100.0;
         if(LabSelectPositionById(posId))
           {
            double loss = 0;
            long typ = PositionGetInteger(POSITION_TYPE);
            if(OrderCalcProfit(typ == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym,
                               PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN),
                               PositionGetDouble(POSITION_SL), loss))
               if(MathAbs(loss) > 0)
                  riskMoney = MathAbs(loss);
           }
         for(int i = 0; i < LAB_LIVE; i++)
            if(!g_labLive[i].used)
              {
               g_labLive[i].used = true;
               g_labLive[i].posId = posId;
               g_labLive[i].strat = s;
               g_labLive[i].sym = sym;
               g_labLive[i].dir = sig.dir;
               g_labLive[i].riskMoney = riskMoney;
               g_labLive[i].opened = TimeCurrent();
               g_labLive[i].expires = TimeCurrent() + holdSec;
               break;
              }
         LabSaveState();
         return;
        }
     }
   // Benched, blocked by a limit, or the order failed: learn on paper
   LabOpenPaper(s, sym, sig, holdSec);
  }

//==================================================================
// Reports
//==================================================================
string LabLine(int s, bool today)
  {
   LabStat st = g_labSt[s];
   if(today)
      return StringFormat("%s %s: %d trades (%d live), win %d, %+.2fR, $%.2f",
                          StringSubstr(LabCode(s), 0, 2), LabModeName(st.mode), st.dayN, st.dayLiveN,
                          st.dayWins, st.daySumR, st.dayMoney);
   int cnt; double pf, expR, wr;
   LabScore(s, cnt, pf, expR, wr);
   return StringFormat("%-16s %-6s all %3d (live %3d) %+6.2fR $%8.2f | last %2d: PF %4.2f %+.2fR/tr win %3.0f%%",
                       LabCode(s), LabModeName(st.mode), st.n, st.liveN, st.sumR, st.liveMoney,
                       cnt, pf, expR, wr);
  }

string LabPanel()
  {
   string t = "Lab (TRIAL=small risk, ACTIVE=full, PAPER=virtual only):\n";
   for(int s = 0; s < LAB_N; s++)
      if(g_labSt[s].mode != LAB_OFF)
         t += LabLine(s, false) + "\n";
   return t;
  }

void LabSendDailyReport(long dayKey)
  {
   string full = StringFormat("=== PropGuard Lab day %I64d ===\n", dayKey);
   int totN = 0; double totR = 0, totMoney = 0;
   string push = "";
   for(int s = 0; s < LAB_N; s++)
     {
      if(g_labSt[s].mode == LAB_OFF)
         continue;
      full += "today " + LabLine(s, true) + "\n";
      full += "      " + LabLine(s, false) + "\n";
      totN += g_labSt[s].dayN;
      totR += g_labSt[s].daySumR;
      totMoney += g_labSt[s].dayMoney;
      if(g_labSt[s].dayN > 0)
         push += StringFormat("%s %s %d/%+.1fR; ", StringSubstr(LabCode(s), 0, 2),
                              LabModeName(g_labSt[s].mode), g_labSt[s].dayN, g_labSt[s].daySumR);
     }
   full += StringFormat("TOTAL today: %d results, %+.2fR, live $%.2f, balance %.2f\n", totN, totR, totMoney,
                        AccountInfoDouble(ACCOUNT_BALANCE));
   Print(full);
   int h = FileOpen(LabFile("_report"), FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h != INVALID_HANDLE)
     {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, full + "\n");
      FileClose(h);
     }
   Notify(StringFormat("Lab day %I64d: %d trades, %+.1fR, $%.2f. %s", dayKey, totN, totR, totMoney, push));
   for(int s = 0; s < LAB_N; s++)
     {
      g_labSt[s].dayN = 0; g_labSt[s].dayWins = 0; g_labSt[s].daySumR = 0;
      g_labSt[s].dayLiveN = 0; g_labSt[s].dayMoney = 0;
     }
  }

void LabMaybeReport()
  {
   long today = LabDayKey(TimeCurrent());
   // Report once per day at the server day change; g_labReportDay = the day the counters belong to
   if(today != g_labReportDay)
     {
      LabSendDailyReport(g_labReportDay);
      g_labReportDay = today;
      LabSaveState();
     }
  }
//+------------------------------------------------------------------+
#endif
