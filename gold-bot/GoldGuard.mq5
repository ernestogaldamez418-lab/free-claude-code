//+------------------------------------------------------------------+
//|                                                    GoldGuard.mq5 |
//|  EA de oro (XAUUSD) para MetaTrader 5 con gestion de riesgo      |
//|  por capas. Estrategia: pullback a favor de la tendencia.        |
//|  USAR PRIMERO EN CUENTA DEMO. No garantiza ganancias.            |
//+------------------------------------------------------------------+
#property copyright "GoldGuard"
#property version   "1.00"
#property description "Pullback con tendencia en XAUUSD + riesgo por capas"
#property strict

#include <Trade/Trade.mqh>

enum ENUM_LOT_MODE { LOT_RISK_PERCENT = 0, LOT_LADDER = 1 };

//--- General
input group "=== General ==="
input long   InpMagic            = 20260501;   // Magic number
input string InpComment          = "GoldGuard";// Comentario de ordenes
input bool   InpAllowBuy         = true;       // Permitir compras
input bool   InpAllowSell        = true;       // Permitir ventas
input bool   InpPush             = true;       // Notificaciones push al celular
input int    InpSlippage         = 30;         // Desviacion maxima (puntos)

//--- Estrategia
input group "=== Estrategia ==="
input ENUM_TIMEFRAMES InpEntryTF = PERIOD_M15; // Timeframe de entrada
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H1;  // Timeframe de tendencia
input int    InpTrendFast        = 50;         // EMA tendencia rapida
input int    InpTrendSlow        = 200;        // EMA tendencia lenta
input int    InpPullbackEMA      = 21;         // EMA de pullback (timeframe entrada)
input int    InpRsiPeriod        = 14;         // Periodo RSI
input double InpRsiMin           = 40.0;       // RSI minimo (compra) / 100-max (venta)
input double InpRsiMax           = 65.0;       // RSI maximo (compra) / 100-min (venta)
input int    InpAdxPeriod        = 14;         // Periodo ADX (timeframe tendencia)
input double InpAdxMin           = 20.0;       // ADX minimo (hay tendencia)
input int    InpAtrPeriod        = 14;         // Periodo ATR (timeframe entrada)

//--- Stop / Take
input group "=== SL / TP / Gestion de la posicion ==="
input double InpSlAtrMult        = 1.5;        // SL = ATR x esto
input double InpRR               = 2.0;        // Take Profit = SL x esto (ratio R:R)
input double InpBreakEvenR       = 1.0;        // Mover a break-even al llegar a X R
input double InpBreakEvenLockR   = 0.1;        // Asegurar X R al mover a break-even
input bool   InpUseTrailing      = true;       // Trailing stop por ATR
input double InpTrailStartR      = 1.5;        // Iniciar trailing al llegar a X R
input double InpTrailAtrMult     = 1.2;        // Distancia trailing = ATR x esto

//--- Riesgo
input group "=== Riesgo ==="
input ENUM_LOT_MODE InpLotMode   = LOT_LADDER; // Modo de lote: escalera o % de riesgo
input double InpLadderStepUSD    = 10.0;       // [Escalera] USD de equity por cada escalon
input double InpLadderLot        = 0.01;       // [Escalera] lotes por escalon (0.01 por cada 10 USD)
input double InpLadderMaxRiskPct = 60.0;       // [Escalera] no entrar si el SL pierde > X % de la cuenta
input double InpRiskPercent      = 0.5;        // [% riesgo] % de equity arriesgado por operacion
input double InpMaxLots          = 1.0;        // Lote maximo absoluto
input double InpMaxRiskOverrun   = 1.5;        // Si el lote minimo arriesga > X veces lo planeado, no operar
input int    InpMaxPositions     = 1;          // Posiciones abiertas maximas
input int    InpMaxTradesPerDay  = 3;          // Operaciones maximas por dia
input int    InpMaxConsecLosses  = 2;          // Perdidas seguidas -> pausa el resto del dia
input double InpMaxDailyLossPct  = 2.0;        // Perdida diaria maxima % (cierra todo y para)
input double InpMaxDrawdownPct   = 8.0;        // Drawdown maximo desde pico % (cierra todo y BLOQUEA)
input bool   InpResetHalt        = false;      // true = quitar el bloqueo de drawdown al iniciar
input double InpMinFreeMarginX   = 3.0;        // Margen libre debe ser >= X veces el margen requerido

//--- Filtros
input group "=== Filtros de mercado ==="
input int    InpMaxSpreadPts     = 40;         // Spread maximo (puntos; en oro 40 = 0.40 USD)
input double InpMaxAtrSpike      = 2.5;        // No operar si ATR > X veces su promedio (noticias)
input double InpMinAtrRatio      = 0.6;        // No operar si ATR < X veces su promedio (mercado muerto)
input int    InpSessionStartHour = 10;         // Inicio sesion (hora del SERVIDOR)
input int    InpSessionEndHour   = 20;         // Fin sesion (hora del SERVIDOR)
input string InpNoTradeWindows   = "15:25-15:50"; // Ventanas sin operar HH:MM-HH:MM;... (hora servidor)
input bool   InpCloseFriday      = true;       // Cerrar todo el viernes
input int    InpFridayCloseHour  = 20;         // Hora de cierre viernes (servidor)

//--- Globals
CTrade   g_trade;
int      g_hEmaFast, g_hEmaSlow, g_hAdx;       // timeframe tendencia
int      g_hEmaPb, g_hRsi, g_hAtr;             // timeframe entrada
datetime g_lastBar     = 0;
datetime g_dayStamp    = 0;
double   g_dayStartEq  = 0;
double   g_peakEq      = 0;
bool     g_dayHalted   = false;
bool     g_ddHalted    = false;
string   g_gvPrefix;
string   g_status      = "";
datetime g_lastDash    = 0;

//+------------------------------------------------------------------+
//| Utilidades                                                       |
//+------------------------------------------------------------------+
bool CopyBuf(const int handle, const int shift, const int count, double &arr[])
{
   ArraySetAsSeries(arr, true);
   return(CopyBuffer(handle, 0, shift, count, arr) == count);
}

int ParseHM(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   string hm[];
   if(StringSplit(s, ':', hm) != 2) return(-1);
   return((int)StringToInteger(hm[0]) * 60 + (int)StringToInteger(hm[1]));
}

bool InNoTradeWindow(const datetime t)
{
   if(StringLen(InpNoTradeWindows) == 0) return(false);
   string parts[];
   int n = StringSplit(InpNoTradeWindows, ';', parts);
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int cur = dt.hour * 60 + dt.min;
   for(int i = 0; i < n; i++)
   {
      string se[];
      if(StringSplit(parts[i], '-', se) != 2) continue;
      int a = ParseHM(se[0]), b = ParseHM(se[1]);
      if(a < 0 || b < 0) continue;
      if(a <= b) { if(cur >= a && cur <= b) return(true); }
      else       { if(cur >= a || cur <= b) return(true); }
   }
   return(false);
}

void Notify(const string msg)
{
   Print("GoldGuard: ", msg);
   if(InpPush) SendNotification("GoldGuard: " + msg);
}

int LotDigits(const double step)
{
   int d = 0;
   double s = step;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1e-8) { s *= 10.0; d++; }
   return(d);
}

//+------------------------------------------------------------------+
//| Posiciones                                                       |
//+------------------------------------------------------------------+
bool IsMine()
{
   return(PositionGetString(POSITION_SYMBOL) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic);
}

int CountPositions()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(IsMine()) c++;
   }
   return(c);
}

void CloseAll(const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !IsMine()) continue;
      if(!g_trade.PositionClose(tk))
         Print("GoldGuard: fallo al cerrar ", tk, " err=", GetLastError());
   }
   Print("GoldGuard: cierre total por: ", reason);
}

//+------------------------------------------------------------------+
//| Estado persistente (sobrevive a reinicios del terminal)          |
//+------------------------------------------------------------------+
void SaveState()
{
   GlobalVariableSet(g_gvPrefix + "DAYEQ", g_dayStartEq);
   GlobalVariableSet(g_gvPrefix + "DAYTS", (double)g_dayStamp);
   GlobalVariableSet(g_gvPrefix + "PEAK",  g_peakEq);
   GlobalVariableSet(g_gvPrefix + "DAYHALT", g_dayHalted ? 1.0 : 0.0);
   GlobalVariableSet(g_gvPrefix + "DDHALT",  g_ddHalted ? 1.0 : 0.0);
}

void LoadState()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEq     = GlobalVariableCheck(g_gvPrefix + "PEAK")  ? GlobalVariableGet(g_gvPrefix + "PEAK")  : eq;
   g_dayStartEq = GlobalVariableCheck(g_gvPrefix + "DAYEQ") ? GlobalVariableGet(g_gvPrefix + "DAYEQ") : eq;
   g_dayStamp   = GlobalVariableCheck(g_gvPrefix + "DAYTS") ? (datetime)GlobalVariableGet(g_gvPrefix + "DAYTS") : 0;
   g_dayHalted  = GlobalVariableCheck(g_gvPrefix + "DAYHALT") && GlobalVariableGet(g_gvPrefix + "DAYHALT") > 0.5;
   g_ddHalted   = GlobalVariableCheck(g_gvPrefix + "DDHALT")  && GlobalVariableGet(g_gvPrefix + "DDHALT")  > 0.5;
   if(InpResetHalt)
   {
      g_ddHalted = false;
      g_peakEq   = eq;
   }
}

//+------------------------------------------------------------------+
//| Control de riesgo global                                         |
//+------------------------------------------------------------------+
// Devuelve true si se permite seguir operando
bool RiskGate()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   // Nuevo dia (del servidor)
   datetime d = iTime(_Symbol, PERIOD_D1, 0);
   if(d != 0 && d != g_dayStamp)
   {
      g_dayStamp   = d;
      g_dayStartEq = eq;
      g_dayHalted  = false;
      SaveState();
   }

   if(eq > g_peakEq) { g_peakEq = eq; SaveState(); }

   // Drawdown maximo desde el pico -> bloqueo total
   if(g_peakEq > 0)
   {
      double dd = (g_peakEq - eq) / g_peakEq * 100.0;
      if(dd >= InpMaxDrawdownPct && !g_ddHalted)
      {
         g_ddHalted = true;
         CloseAll("drawdown maximo");
         SaveState();
         Notify(StringFormat("BLOQUEADO: drawdown %.2f%% >= %.2f%%. Revisa antes de reactivar (InpResetHalt).", dd, InpMaxDrawdownPct));
      }
   }
   if(g_ddHalted) { g_status = "BLOQUEADO por drawdown maximo"; return(false); }

   // Perdida diaria maxima
   if(g_dayStartEq > 0)
   {
      double dl = (g_dayStartEq - eq) / g_dayStartEq * 100.0;
      if(dl >= InpMaxDailyLossPct && !g_dayHalted)
      {
         g_dayHalted = true;
         CloseAll("perdida diaria maxima");
         SaveState();
         Notify(StringFormat("Parado por hoy: perdida diaria %.2f%%.", dl));
      }
   }
   if(g_dayHalted) { g_status = "Pausado: perdida diaria maxima"; return(false); }

   return(true);
}

// Operaciones de hoy y perdidas consecutivas (solo este EA)
void ScanToday(int &trades, int &consecLoss, double &pnl)
{
   trades = 0; consecLoss = 0; pnl = 0;
   datetime from = iTime(_Symbol, PERIOD_D1, 0);
   if(from == 0 || !HistorySelect(from, TimeCurrent() + 60)) return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
      long e = HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(e == DEAL_ENTRY_IN) trades++;
      else if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_INOUT || e == DEAL_ENTRY_OUT_BY)
      {
         double p = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP)
                  + HistoryDealGetDouble(tk, DEAL_COMMISSION);
         pnl += p;
         if(p < 0) consecLoss++; else consecLoss = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Tamano de lote por riesgo fijo                                   |
//+------------------------------------------------------------------+
double CalcLots(const double slDist)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0) tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0 || slDist <= 0 || riskMoney <= 0) return(0);

   double lossPerLot = slDist / tickSize * tickVal;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) return(0);

   if(InpLotMode == LOT_LADDER)
   {
      // Escalera: InpLadderLot por cada InpLadderStepUSD de equity (minimo 1 escalon)
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double steps = MathMax(1.0, MathFloor(eq / InpLadderStepUSD));
      double l = MathMax(minL, MathFloor(steps * InpLadderLot / step) * step);
      l = MathMin(l, MathMin(maxL, InpMaxLots));
      // tope de seguridad: no entrar si el SL perderia demasiado % de la cuenta
      if(l * lossPerLot > eq * InpLadderMaxRiskPct / 100.0) return(0);
      return(NormalizeDouble(l, LotDigits(step)));
   }

   double lots = MathFloor(riskMoney / lossPerLot / step) * step;
   if(lots < minL)
   {
      if(minL * lossPerLot > riskMoney * InpMaxRiskOverrun) return(0); // cuenta muy chica para este SL
      lots = minL;
   }
   lots = MathMin(lots, MathMin(maxL, InpMaxLots));
   return(NormalizeDouble(lots, LotDigits(step)));
}

//+------------------------------------------------------------------+
//| Filtros de mercado                                               |
//+------------------------------------------------------------------+
bool MarketOK(const double atr, const double atrAvg)
{
   MqlDateTime dt;
   datetime now = TimeCurrent();
   TimeToStruct(now, dt);

   if(dt.hour < InpSessionStartHour || dt.hour >= InpSessionEndHour)
      { g_status = "Fuera de sesion"; return(false); }
   if(InNoTradeWindow(now))
      { g_status = "Ventana sin operar (noticias)"; return(false); }
   if(InpCloseFriday && dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour - 2)
      { g_status = "Viernes: sin nuevas entradas"; return(false); }
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      { g_status = "Fin de semana"; return(false); }

   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spreadPts > InpMaxSpreadPts)
      { g_status = StringFormat("Spread alto (%.0f pts)", spreadPts); return(false); }

   if(atrAvg > 0 && atr > atrAvg * InpMaxAtrSpike)
      { g_status = "Volatilidad extrema (ATR spike)"; return(false); }
   if(atrAvg > 0 && atr < atrAvg * InpMinAtrRatio)
      { g_status = "Mercado muerto (ATR bajo)"; return(false); }

   return(true);
}

//+------------------------------------------------------------------+
//| Senal de entrada: 1 = compra, -1 = venta, 0 = nada               |
//+------------------------------------------------------------------+
int Signal(double &atr, double &atrAvg)
{
   double emaF[], emaS[], adx[], pb[], rsi[], atrA[];
   if(!CopyBuf(g_hEmaFast, 0, 3, emaF)) return(0);
   if(!CopyBuf(g_hEmaSlow, 0, 3, emaS)) return(0);
   if(!CopyBuf(g_hAdx,     0, 3, adx))  return(0);
   if(!CopyBuf(g_hEmaPb,   0, 3, pb))   return(0);
   if(!CopyBuf(g_hRsi,     0, 3, rsi))  return(0);
   if(!CopyBuf(g_hAtr,     1, 50, atrA)) return(0);   // ATR de velas cerradas

   atr = atrA[0];
   double sum = 0;
   for(int i = 0; i < 50; i++) sum += atrA[i];
   atrAvg = sum / 50.0;

   // Tendencia en TF alto (vela cerrada = indice 1)
   double trendClose = iClose(_Symbol, InpTrendTF, 1);
   bool up   = emaF[1] > emaS[1] && trendClose > emaS[1];
   bool down = emaF[1] < emaS[1] && trendClose < emaS[1];
   if(adx[1] < InpAdxMin) { g_status = "Sin tendencia (ADX bajo)"; return(0); }

   // Vela de entrada cerrada (indice 1)
   double o = iOpen(_Symbol,  InpEntryTF, 1);
   double c = iClose(_Symbol, InpEntryTF, 1);
   double h = iHigh(_Symbol,  InpEntryTF, 1);
   double l = iLow(_Symbol,   InpEntryTF, 1);

   // Compra: tendencia alcista, la vela toco la EMA y cerro arriba (alcista), RSI sano y subiendo
   if(up && InpAllowBuy && l <= pb[1] && c > pb[1] && c > o &&
      rsi[1] >= InpRsiMin && rsi[1] <= InpRsiMax && rsi[1] > rsi[2])
      return(1);

   // Venta: espejo
   if(down && InpAllowSell && h >= pb[1] && c < pb[1] && c < o &&
      rsi[1] <= 100.0 - InpRsiMin && rsi[1] >= 100.0 - InpRsiMax && rsi[1] < rsi[2])
      return(-1);

   g_status = "Esperando setup";
   return(0);
}

//+------------------------------------------------------------------+
//| Ejecutar entrada                                                 |
//+------------------------------------------------------------------+
void OpenTrade(const int dir, const double atr)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minStop = (double)MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                    SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;

   double slDist = atr * InpSlAtrMult;
   if(slDist < minStop + (ask - bid)) slDist = minStop + (ask - bid);   // respeta el nivel minimo del broker
   double tpDist = slDist * InpRR;

   double price = (dir > 0) ? ask : bid;
   double sl = (dir > 0) ? price - slDist : price + slDist;
   double tp = (dir > 0) ? price + tpDist : price - tpDist;
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double lots = CalcLots(slDist);
   if(lots <= 0) { g_status = "Lote 0: cuenta chica para este riesgo"; return; }

   // Margen
   double margin = 0;
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(ot, _Symbol, lots, price, margin)) return;
   double needX = (InpLotMode == LOT_LADDER) ? MathMin(InpMinFreeMarginX, 1.1) : InpMinFreeMarginX;
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin * needX)
      { g_status = "Margen libre insuficiente"; return; }

   bool ok = (dir > 0) ? g_trade.Buy(lots, _Symbol, price, sl, tp, InpComment)
                       : g_trade.Sell(lots, _Symbol, price, sl, tp, InpComment);
   if(ok && (g_trade.ResultRetcode() == TRADE_RETCODE_DONE || g_trade.ResultRetcode() == TRADE_RETCODE_PLACED))
      Notify(StringFormat("%s %.2f lotes @ %.2f SL %.2f TP %.2f (riesgo %.2f%%)",
             dir > 0 ? "COMPRA" : "VENTA", lots, price, sl, tp, InpRiskPercent));
   else
      Print("GoldGuard: orden rechazada retcode=", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Gestion: break-even y trailing (cada tick)                       |
//+------------------------------------------------------------------+
void ManagePositions()
{
   double atrA[];
   bool haveAtr = CopyBuf(g_hAtr, 1, 1, atrA);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !IsMine()) continue;

      bool buy   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      if(tp <= 0 || InpRR <= 0) continue;

      double R = MathAbs(tp - op) / InpRR;              // riesgo inicial en precio
      double cur = buy ? bid : ask;
      double profit = buy ? cur - op : op - cur;
      double newSl = sl;

      if(profit >= R * InpBreakEvenR)
      {
         double be = buy ? op + R * InpBreakEvenLockR : op - R * InpBreakEvenLockR;
         if(buy  && (sl == 0 || be > newSl)) newSl = be;
         if(!buy && (sl == 0 || be < newSl)) newSl = be;
      }
      if(InpUseTrailing && haveAtr && profit >= R * InpTrailStartR)
      {
         double t = buy ? cur - atrA[0] * InpTrailAtrMult : cur + atrA[0] * InpTrailAtrMult;
         if(buy  && t > newSl) newSl = t;
         if(!buy && (newSl == 0 || t < newSl)) newSl = t;
      }

      newSl = NormalizeDouble(newSl, digits);
      if(newSl == sl || newSl == 0) continue;
      // respetar distancia minima al precio
      if(buy  && newSl > bid - minStop) continue;
      if(!buy && newSl < ask + minStop) continue;
      // solo mover a favor
      if(buy  && sl != 0 && newSl <= sl) continue;
      if(!buy && sl != 0 && newSl >= sl) continue;

      g_trade.PositionModify(tk, newSl, tp);
   }
}

//+------------------------------------------------------------------+
//| Panel en el grafico                                              |
//+------------------------------------------------------------------+
void Dashboard()
{
   if(TimeCurrent() == g_lastDash) return;
   g_lastDash = TimeCurrent();
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = g_peakEq > 0 ? (g_peakEq - eq) / g_peakEq * 100.0 : 0;
   double dl = g_dayStartEq > 0 ? (g_dayStartEq - eq) / g_dayStartEq * 100.0 : 0;
   int tr, cl; double pnl;
   ScanToday(tr, cl, pnl);
   Comment("GoldGuard v1.00  |  ", _Symbol, "\n",
           "Estado: ", g_status, "\n",
           StringFormat("Equity: %.2f   Pico: %.2f\n", eq, g_peakEq),
           StringFormat("DD desde pico: %.2f%% / %.1f%%\n", dd, InpMaxDrawdownPct),
           StringFormat("Perdida hoy: %.2f%% / %.1f%%\n", dl, InpMaxDailyLossPct),
           StringFormat("Trades hoy: %d / %d   Perdidas seguidas: %d / %d\n", tr, InpMaxTradesPerDay, cl, InpMaxConsecLosses),
           StringFormat("Posiciones: %d / %d", CountPositions(), InpMaxPositions));
}

//+------------------------------------------------------------------+
//| Eventos                                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   string s = _Symbol;
   StringToUpper(s);
   if(StringFind(s, "XAU") < 0 && StringFind(s, "GOLD") < 0)
      Print("GoldGuard: AVISO - el simbolo ", _Symbol, " no parece oro. Disenado para XAUUSD.");

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      Print("GoldGuard: AVISO - trading automatico no permitido (activa 'Algo Trading').");

   if(InpRiskPercent <= 0 || InpRiskPercent > 5.0)
      { Print("GoldGuard: InpRiskPercent debe estar entre 0 y 5."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpRR <= 0 || InpSlAtrMult <= 0)
      { Print("GoldGuard: RR y SL ATR deben ser > 0."); return(INIT_PARAMETERS_INCORRECT); }

   g_hEmaFast = iMA(_Symbol, InpTrendTF, InpTrendFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow = iMA(_Symbol, InpTrendTF, InpTrendSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAdx     = iADX(_Symbol, InpTrendTF, InpAdxPeriod);
   g_hEmaPb   = iMA(_Symbol, InpEntryTF, InpPullbackEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hRsi     = iRSI(_Symbol, InpEntryTF, InpRsiPeriod, PRICE_CLOSE);
   g_hAtr     = iATR(_Symbol, InpEntryTF, InpAtrPeriod);
   if(g_hEmaFast == INVALID_HANDLE || g_hEmaSlow == INVALID_HANDLE || g_hAdx == INVALID_HANDLE ||
      g_hEmaPb == INVALID_HANDLE || g_hRsi == INVALID_HANDLE || g_hAtr == INVALID_HANDLE)
      { Print("GoldGuard: error creando indicadores."); return(INIT_FAILED); }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_gvPrefix = StringFormat("GG_%I64d_%I64d_%s_", AccountInfoInteger(ACCOUNT_LOGIN), InpMagic, _Symbol);
   LoadState();
   g_status = "Iniciado";
   Print("GoldGuard iniciado en ", _Symbol);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   SaveState();
   Comment("");
   IndicatorRelease(g_hEmaFast); IndicatorRelease(g_hEmaSlow); IndicatorRelease(g_hAdx);
   IndicatorRelease(g_hEmaPb);   IndicatorRelease(g_hRsi);     IndicatorRelease(g_hAtr);
}

void OnTick()
{
   if(!RiskGate()) { Dashboard(); return; }

   // Cierre de viernes
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpCloseFriday && dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour && CountPositions() > 0)
      CloseAll("cierre de viernes");

   ManagePositions();

   // Solo evaluamos entradas una vez por vela nueva
   datetime bar = iTime(_Symbol, InpEntryTF, 0);
   if(bar == 0 || bar == g_lastBar) { Dashboard(); return; }
   g_lastBar = bar;

   if(CountPositions() >= InpMaxPositions) { g_status = "Posicion abierta"; Dashboard(); return; }

   int trades, consec; double pnl;
   ScanToday(trades, consec, pnl);
   if(trades >= InpMaxTradesPerDay)      { g_status = "Limite de trades diarios"; Dashboard(); return; }
   if(consec >= InpMaxConsecLosses)      { g_status = "Pausa: perdidas seguidas"; Dashboard(); return; }

   double atr = 0, atrAvg = 0;
   int sig = Signal(atr, atrAvg);
   if(sig != 0 && atr > 0 && MarketOK(atr, atrAvg))
      OpenTrade(sig, atr);

   Dashboard();
}
//+------------------------------------------------------------------+
