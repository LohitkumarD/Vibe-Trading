#ifndef PG_NOTIFIER
#define PG_NOTIFIER
//+------------------------------------------------------------------+
//| Notifier.mqh - MT5 native push alerts to the MT5 mobile app      |
//| Uses SendNotification() only (no Telegram/WhatsApp: some firms   |
//| ban EAs that connect to messengers).                             |
//+------------------------------------------------------------------+

datetime g_lastPush = 0;

void Notify(string msg, bool push = true)
  {
   string text = "PropGuard " + _Symbol + ": " + msg;
   Print(text);
   if(!push || MQLInfoInteger(MQL_TESTER))
      return;
   if(!TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      return;
   // MT5 allows at most 2 pushes/second and 10/minute; keep a 7 s gap.
   if(TimeLocal() - g_lastPush < 7)
      return;
   if(SendNotification(StringSubstr(text, 0, 255)))
      g_lastPush = TimeLocal();
  }
//+------------------------------------------------------------------+
#endif
