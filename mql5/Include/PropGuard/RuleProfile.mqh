#ifndef PG_RULEPROFILE
#define PG_RULEPROFILE
//+------------------------------------------------------------------+
//| RuleProfile.mqh - prop-firm rule presets                         |
//| Every preset number must be verified on the firm's own help page |
//| for the exact account you bought before trading it.              |
//+------------------------------------------------------------------+

enum ENUM_PROP_FIRM
  {
   FIRM_FTMO_2STEP = 0,     // FTMO 2-Step (5% daily / 10% max, static)
   FIRM_FUNDEDNEXT_2STEP,   // FundedNext Stellar 2-Step (5% / 10%)
   FIRM_FUNDEDNEXT_1STEP,   // FundedNext Stellar 1-Step (3% / 6%)
   FIRM_THE5ERS_HIGHSTAKES, // The5ers High Stakes (5% / 10%)
   FIRM_CUSTOM              // Custom (use the Custom inputs below)
  };

enum ENUM_DAILY_BASIS
  {
   BASIS_BALANCE = 0,       // Balance at day start
   BASIS_MAX_BAL_EQ         // Higher of balance/equity at day start (safest)
  };

enum ENUM_RESET_CLOCK
  {
   RESET_CET_MIDNIGHT = 0,  // Midnight Europe/Prague (CET/CEST), e.g. FTMO
   RESET_SERVER_MIDNIGHT    // Midnight of the MT5 server clock, e.g. FundedNext
  };

struct RuleProfile
  {
   string            name;
   double            dailyLossPct;     // % of initial balance
   double            maxLossPct;       // % of initial balance
   bool              maxLossTrailing;  // trailing from balance high-water mark
   ENUM_DAILY_BASIS  dailyBasis;
   ENUM_RESET_CLOCK  resetClock;
   double            profitTargetPct;  // 0 = funded account (no target)
  };

//--- Fill a profile from a preset. Custom values are used for FIRM_CUSTOM.
void LoadRuleProfile(ENUM_PROP_FIRM firm, RuleProfile &p,
                     double cDaily, double cMax, bool cTrailing,
                     ENUM_DAILY_BASIS cBasis, ENUM_RESET_CLOCK cReset,
                     double cTarget)
  {
   // Conservative default for every preset: anchor the daily loss on the
   // higher of balance/equity at reset. That is never looser than the firm.
   p.dailyBasis = BASIS_MAX_BAL_EQ;
   p.maxLossTrailing = false;
   p.profitTargetPct = 10.0;
   switch(firm)
     {
      case FIRM_FTMO_2STEP:
         p.name = "FTMO 2-Step"; p.dailyLossPct = 5.0; p.maxLossPct = 10.0;
         p.resetClock = RESET_CET_MIDNIGHT; break;
      case FIRM_FUNDEDNEXT_2STEP:
         p.name = "FundedNext Stellar 2-Step"; p.dailyLossPct = 5.0; p.maxLossPct = 10.0;
         p.resetClock = RESET_SERVER_MIDNIGHT; p.profitTargetPct = 8.0; break;
      case FIRM_FUNDEDNEXT_1STEP:
         p.name = "FundedNext Stellar 1-Step"; p.dailyLossPct = 3.0; p.maxLossPct = 6.0;
         p.resetClock = RESET_SERVER_MIDNIGHT; break;
      case FIRM_THE5ERS_HIGHSTAKES:
         p.name = "The5ers High Stakes"; p.dailyLossPct = 5.0; p.maxLossPct = 10.0;
         p.resetClock = RESET_SERVER_MIDNIGHT; p.profitTargetPct = 8.0; break;
      default:
         p.name = "Custom"; p.dailyLossPct = cDaily; p.maxLossPct = cMax;
         p.maxLossTrailing = cTrailing; p.dailyBasis = cBasis;
         p.resetClock = cReset; p.profitTargetPct = cTarget; break;
     }
  }
//+------------------------------------------------------------------+
#endif
