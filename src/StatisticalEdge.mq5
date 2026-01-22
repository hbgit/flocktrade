//+------------------------------------------------------------------+
//|                                   StatisticalEdge.mq5            |
//|                    Estratégia Matemática com 4 Modelos           |
//|              Bollinger + RSI + Structure + Stochastic            |
//+------------------------------------------------------------------+
#property copyright "hbgit, 2026."
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//============================================================================
// INPUTS - PARÂMETROS OTIMIZADOS MATEMATICAMENTE
//============================================================================

input group "=== GERENCIAMENTO DE RISCO ==="
input double RiskPercent = 1.0;        // Risco por operação (% capital)
input double RiskRewardRatio = 1.8;    // Razão Risco:Retorno mínima
input int DailyLossLimit = 250;        // Limite de perda diária (pontos)

input group "=== MODELO 1: MEAN REVERSION (Bollinger) ==="
input int BB_Period = 20;              // Período das Bandas
input double BB_Deviation = 2.0;       // Desvios Padrão
input bool UseMeanReversion = true;    // Ativar modelo
input int MeanRev_Weight = 1;          // Peso do voto (1-3)

input group "=== MODELO 2: MOMENTUM (RSI + Volume) ==="
input int RSI_Period = 14;             // Período do RSI
input int RSI_Oversold = 30;           // Nível de sobrevenda
input int RSI_Overbought = 70;         // Nível de sobrecompra
input int Volume_Period = 20;          // Período para média de volume
input double Volume_Multiplier = 1.5;  // Multiplicador de volume
input bool UseMomentum = true;         // Ativar modelo
input int Momentum_Weight = 1;         // Peso do voto (1-3)

input group "=== MODELO 3: STRUCTURE (Suporte/Resistência) ==="
input int Pivot_Lookback = 10;         // Candles para pivots
input double SR_Tolerance = 0.0015;    // Tolerância S/R (0.15%)
input bool UseStructure = true;        // Ativar modelo
input int Structure_Weight = 2;        // Peso do voto (1-3) - MAIOR!

input group "=== MODELO 4: STOCHASTIC (Oscilador) ==="
input int Stoch_K_Period = 14;         // Período %K
input int Stoch_D_Period = 3;          // Período %D (smoothing)
input int Stoch_Slowing = 3;           // Slowing
input int Stoch_Oversold = 20;         // Nível sobrevenda
input int Stoch_Overbought = 80;       // Nível sobrecompra
input bool UseStochastic = true;       // Ativar modelo
input int Stochastic_Weight = 1;       // Peso do voto (1-3)
input bool Stoch_UseDivergence = true; // Detectar divergências

input group "=== FILTROS COMPLEMENTARES ==="
input int EMA_Fast = 9;                // EMA Rápida (tendência)
input int EMA_Slow = 21;               // EMA Lenta (tendência)
input int ATR_Period = 14;             // Período ATR
input double ATR_MinMultiplier = 1.2;  // ATR mínimo (volatilidade)
input int MaxSpread = 10;              // Spread máximo (pontos)
input double MaxSpreadPercentSL = 20.0; // Spread máximo em % do SL

input group "=== SISTEMA DE VOTAÇÃO ==="
input int MinVotesRequired = 3;        // Votos mínimos para entrada (ponderado)

input group "=== HORÁRIOS ==="
input int StartHour1 = 10;             // Início Manhã
input int EndHour1 = 11;               // Fim Manhã
input int StartHour2 = 14;             // Início Tarde
input int EndHour2 = 16;               // Fim Tarde

input group "=== STOP LOSS DINÂMICO ==="
input bool UseATRStop = true;          // Stop baseado em ATR
input double ATR_StopMultiplier = 2.5; // Multiplicador ATR para SL
input int MinStopPoints = 100;         // Stop mínimo (pontos)
input int MaxStopPoints = 200;         // Stop máximo (pontos)

input group "=== GERENCIAMENTO DE POSIÇÃO ==="
input double BreakEvenTrigger = 0.6;   // BE em % do TP (60%)
input double BreakEvenOffset = 0.5;    // Offset do BE (50% lucro)
input double TrailingStart = 0.6;      // Início trailing (60% TP)
input double TrailingStep = 0.3;       // Step trailing (30% movimento)
input int MinDelayBreakEvenBars = 5;   // Delay mínimo para BE (candles)
input int MinDelayTrailingBars = 8;    // Delay mínimo para trailing (candles)

//============================================================================
// VARIÁVEIS GLOBAIS
//============================================================================

int handleBB, handleRSI, handleEMA_Fast, handleEMA_Slow, handleATR, handleStoch;
double lotSize;
bool tradingBlocked = false;
int lastDay = -1;
static datetime lastBarTime = 0;
double dailyLossInPoints = 0.0;

// Arrays para detecção de divergências
double stochHistory[], priceHistory[];
int historySize = 20;

// Rastreamento de tempo da posição
static datetime positionOpenTime = 0;
static int barsAtPositionOpen = 0;

//============================================================================
// FUNÇÕES MATEMÁTICAS E UTILITÁRIAS
//============================================================================

double NormalizePrice(double price) {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

double CalculateLotSize(double stopLossPoints) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPercent / 100.0;
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pointValue = tickValue * (_Point / tickSize);
   
   double lots = riskMoney / (stopLossPoints * pointValue);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   
   return lots;
}

bool IsTradingTime() {
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   int hour = tm.hour;
   
   return ((hour >= StartHour1 && hour < EndHour1) || 
           (hour >= StartHour2 && hour < EndHour2));
}

bool IsNewBar() {
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBarTime != lastBarTime) {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| MODELO 1: Mean Reversion (Bollinger Bands)                       |
//+------------------------------------------------------------------+
int SignalMeanReversion() {
   if(!UseMeanReversion) return 0;
   
   double bb_upper[], bb_lower[], bb_middle[];
   double close[];
   
   if(CopyBuffer(handleBB, 1, 1, 3, bb_upper) < 3) return 0;
   if(CopyBuffer(handleBB, 2, 1, 3, bb_lower) < 3) return 0;
   if(CopyBuffer(handleBB, 0, 1, 3, bb_middle) < 3) return 0;
   if(CopyClose(_Symbol, PERIOD_M5, 1, 3, close) < 3) return 0;
   
   // Compra: Toca banda inferior + retorna
   if(close[1] <= bb_lower[1] && close[0] > close[1]) {
      return MeanRev_Weight;
   }
   
   // Venda: Toca banda superior + retorna
   if(close[1] >= bb_upper[1] && close[0] < close[1]) {
      return -MeanRev_Weight;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| MODELO 2: Momentum (RSI + Volume)                                |
//+------------------------------------------------------------------+
int SignalMomentum() {
   if(!UseMomentum) return 0;
   
   double rsi[];
   long volume[];
   
   if(CopyBuffer(handleRSI, 0, 1, 2, rsi) < 2) return 0;
   if(CopyTickVolume(_Symbol, PERIOD_M5, 1, Volume_Period + 1, volume) < Volume_Period + 1) 
      return 0;
   
   double avgVolume = 0;
   for(int i = 1; i <= Volume_Period; i++) 
      avgVolume += volume[i];
   avgVolume /= Volume_Period;
   
   double currentVolume = volume[0];
   
   // Compra: RSI saindo de oversold + volume alto
   if(rsi[1] < RSI_Oversold && rsi[0] > rsi[1] && 
      currentVolume > avgVolume * Volume_Multiplier) {
      return Momentum_Weight;
   }
   
   // Venda: RSI saindo de overbought + volume alto
   if(rsi[1] > RSI_Overbought && rsi[0] < rsi[1] && 
      currentVolume > avgVolume * Volume_Multiplier) {
      return -Momentum_Weight;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| MODELO 3: Structure (Suporte/Resistência)                        |
//+------------------------------------------------------------------+
int SignalStructure() {
   if(!UseStructure) return 0;
   
   double close = iClose(_Symbol, PERIOD_M5, 1);
   double high = iHigh(_Symbol, PERIOD_M5, 1);
   double low = iLow(_Symbol, PERIOD_M5, 1);
   
   double support = 0, resistance = 0;
   
   for(int i = 2; i <= Pivot_Lookback + 2; i++) {
      double lowPivot = iLow(_Symbol, PERIOD_M5, i);
      double highPivot = iHigh(_Symbol, PERIOD_M5, i);
      
      if(lowPivot < iLow(_Symbol, PERIOD_M5, i-1) && 
         lowPivot < iLow(_Symbol, PERIOD_M5, i+1)) {
         support = lowPivot;
      }
      
      if(highPivot > iHigh(_Symbol, PERIOD_M5, i-1) && 
         highPivot > iHigh(_Symbol, PERIOD_M5, i+1)) {
         resistance = highPivot;
      }
   }
   
   double tolerance = close * SR_Tolerance;
   
   // Compra: Próximo ao suporte + rejeição
   if(support > 0 && MathAbs(low - support) < tolerance && close > low) {
      return Structure_Weight;
   }
   
   // Venda: Próximo à resistência + rejeição
   if(resistance > 0 && MathAbs(high - resistance) < tolerance && close < high) {
      return -Structure_Weight;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| MODELO 4: Stochastic Oscillator                                  |
//+------------------------------------------------------------------+
int SignalStochastic() {
   if(!UseStochastic) return 0;
   
   double stoch_main[], stoch_signal[];
   
   // %K = buffer 0 (main line)
   // %D = buffer 1 (signal line)
   if(CopyBuffer(handleStoch, 0, 1, 5, stoch_main) < 5) return 0;
   if(CopyBuffer(handleStoch, 1, 1, 5, stoch_signal) < 5) return 0;
   
   double k_current = stoch_main[0];
   double k_prev = stoch_main[1];
   double d_current = stoch_signal[0];
   double d_prev = stoch_signal[1];
   
   int signal = 0;
   
   //==========================================================================
   // SINAL 1: Cruzamento %K × %D em zonas extremas
   //==========================================================================
   
   // Compra: Cruzamento ascendente em zona de sobrevenda
   if(k_prev < d_prev && k_current > d_current && k_current < Stoch_Oversold) {
      signal = Stochastic_Weight;
   }
   
   // Venda: Cruzamento descendente em zona de sobrecompra
   if(k_prev > d_prev && k_current < d_current && k_current > Stoch_Overbought) {
      signal = -Stochastic_Weight;
   }
   
   //==========================================================================
   // SINAL 2: Divergências (ALTA PRECISÃO - 70%+ win rate)
   //==========================================================================
   
   if(Stoch_UseDivergence && signal == 0) {
      double close[];
      if(CopyClose(_Symbol, PERIOD_M5, 1, 5, close) < 5) return signal;
      
      // Divergência de Alta (Bullish):
      // Preço faz fundo mais baixo, mas Stochastic faz fundo mais alto
      if(close[0] < close[2] && stoch_main[0] > stoch_main[2] && 
         k_current < Stoch_Oversold) {
         signal = Stochastic_Weight * 2;  // Divergência vale 2× mais!
         PrintFormat("DIVERGÊNCIA BULLISH: Preço=%.2f→%.2f | Stoch=%.1f→%.1f",
                     close[2], close[0], stoch_main[2], stoch_main[0]);
      }
      
      // Divergência de Baixa (Bearish):
      // Preço faz topo mais alto, mas Stochastic faz topo mais baixo
      if(close[0] > close[2] && stoch_main[0] < stoch_main[2] && 
         k_current > Stoch_Overbought) {
         signal = -Stochastic_Weight * 2;
         PrintFormat("DIVERGÊNCIA BEARISH: Preço=%.2f→%.2f | Stoch=%.1f→%.1f",
                     close[2], close[0], stoch_main[2], stoch_main[0]);
      }
   }
   
   return signal;
}

//+------------------------------------------------------------------+
//| Filtro de Tendência (EMAs)                                       |
//+------------------------------------------------------------------+
int FilterTrend() {
   double ema_fast[], ema_slow[];
   
   if(CopyBuffer(handleEMA_Fast, 0, 1, 2, ema_fast) < 2) return 0;
   if(CopyBuffer(handleEMA_Slow, 0, 1, 2, ema_slow) < 2) return 0;
   
   if(ema_fast[0] > ema_slow[0] && ema_fast[0] > ema_fast[1]) {
      return +1;
   }
   
   if(ema_fast[0] < ema_slow[0] && ema_fast[0] < ema_fast[1]) {
      return -1;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Calcula Stop Loss Dinâmico                                       |
//+------------------------------------------------------------------+
double CalculateDynamicSL(bool isBuy) {
   double atr[];
   if(CopyBuffer(handleATR, 0, 1, 1, atr) < 1) return 150;
   
   double slPoints;
   
   if(UseATRStop) {
      slPoints = atr[0] / _Point * ATR_StopMultiplier;
   } else {
      slPoints = 150;
   }
   
   slPoints = MathMax(MinStopPoints, MathMin(MaxStopPoints, slPoints));
   
   return slPoints;
}

//+------------------------------------------------------------------+
//| Calcula Perda Diária em Pontos                                   |
//+------------------------------------------------------------------+
double CalculateDailyLossInPoints() {
   double totalLoss = 0.0;
   
   // Buscar histórico de deals do dia
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      
      // Filtrar apenas deals do símbolo atual
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      
      // Filtrar apenas deals fechados no dia de hoje
      datetime dealTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      MqlDateTime dtDeal;
      TimeToStruct(dealTime, dtDeal);
      
      MqlDateTime dtNow;
      TimeToStruct(TimeCurrent(), dtNow);
      
      // Se não é do mesmo dia, pula
      if(dtDeal.day != dtNow.day || dtDeal.mon != dtNow.mon || dtDeal.year != dtNow.year) 
         continue;
      
      // Verificar se é saída de posição (entrada OUT)
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;
      
      // Obter lucro/prejuízo em moeda
      double dealProfit = HistoryDealGetDouble(deal, DEAL_PROFIT);
      if(dealProfit < 0) {
         // Converter para pontos
         double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         double pointValue = tickValue * (_Point / tickSize);
         
         if(pointValue > 0) {
            double lossInPoints = MathAbs(dealProfit) / pointValue;
            totalLoss += lossInPoints;
         }
      }
   }
   
   return totalLoss;
}

//+------------------------------------------------------------------+
//| Verifica Limite de Perda Diária                                  |
//+------------------------------------------------------------------+
bool IsWithinDailyLossLimit() {
   dailyLossInPoints = CalculateDailyLossInPoints();
   
   if(dailyLossInPoints >= DailyLossLimit) {
      if(!tradingBlocked) {
         PrintFormat("=== LIMITE DE PERDA DIÁRIA ATINGIDO ===");
         PrintFormat("Perda: %.0f / Limite: %.0f pontos", dailyLossInPoints, DailyLossLimit);
         PrintFormat("Trading bloqueado até o próximo dia!");
         tradingBlocked = true;
      }
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Verifica Spread Relativo ao Stop Loss                            |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable(double slPoints) {
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - 
                    SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   
   double maxSpreadAllowed = (slPoints * MaxSpreadPercentSL) / 100.0;
   
   if(spread > maxSpreadAllowed) {
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Gestão de Posição com Delay Mínimo                               |
//+------------------------------------------------------------------+
void ManagePosition() {
   if(!PositionSelect(_Symbol)) return;
   
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long type = PositionGetInteger(POSITION_TYPE);
   datetime posOpenTime = (datetime)PositionGetInteger(POSITION_TIME);
   
   // Rastrear abertura da posição apenas na primeira chamada
   if(positionOpenTime != posOpenTime) {
      positionOpenTime = posOpenTime;
      barsAtPositionOpen = 0;
      PrintFormat(">> Posição aberta em: %s | Delay BE: %d candles | Delay Trailing: %d candles",
                  TimeToString(posOpenTime), MinDelayBreakEvenBars, MinDelayTrailingBars);
   }
   
   // Incrementar contador de candles
   barsAtPositionOpen++;
   
   double tpDistance = MathAbs(tp - open);
   double slDistance = MathAbs(sl - open);
   double currentProfit = 0;
   
   // Verificar spread antes de modificar posição
   if(!IsSpreadAcceptable(slDistance)) {
      return;
   }
   
   if(type == POSITION_TYPE_BUY) {
      currentProfit = bid - open;
      
      // Break-Even com delay mínimo
      if(currentProfit >= tpDistance * BreakEvenTrigger && sl < open && 
         barsAtPositionOpen >= MinDelayBreakEvenBars) {
         double bePrice = open + (currentProfit * BreakEvenOffset);
         trade.PositionModify(_Symbol, NormalizePrice(bePrice), tp);
         PrintFormat(">> Break-Even ativado após %d candles (Buy)", barsAtPositionOpen);
      }
      
      // Trailing Stop com delay mínimo
      if(currentProfit >= tpDistance * TrailingStart && 
         barsAtPositionOpen >= MinDelayTrailingBars) {
         double newSL = bid - (tpDistance * TrailingStep);
         if(newSL > sl + 10 * _Point) {
            trade.PositionModify(_Symbol, NormalizePrice(newSL), tp);
            PrintFormat(">> Trailing Stop ativado após %d candles (Buy) | Novo SL: %.5f", 
                        barsAtPositionOpen, newSL);
         }
      }
   }
   else {
      currentProfit = open - ask;
      
      // Break-Even com delay mínimo
      if(currentProfit >= tpDistance * BreakEvenTrigger && (sl > open || sl == 0) && 
         barsAtPositionOpen >= MinDelayBreakEvenBars) {
         double bePrice = open - (currentProfit * BreakEvenOffset);
         trade.PositionModify(_Symbol, NormalizePrice(bePrice), tp);
         PrintFormat(">> Break-Even ativado após %d candles (Sell)", barsAtPositionOpen);
      }
      
      // Trailing Stop com delay mínimo
      if(currentProfit >= tpDistance * TrailingStart && 
         barsAtPositionOpen >= MinDelayTrailingBars) {
         double newSL = ask + (tpDistance * TrailingStep);
         if((newSL < sl - 10 * _Point) || sl == 0) {
            trade.PositionModify(_Symbol, NormalizePrice(newSL), tp);
            PrintFormat(">> Trailing Stop ativado após %d candles (Sell) | Novo SL: %.5f", 
                        barsAtPositionOpen, newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Inicialização                                                    |
//+------------------------------------------------------------------+
int OnInit() {
   handleBB = iBands(_Symbol, PERIOD_M5, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   handleRSI = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   handleEMA_Fast = iMA(_Symbol, PERIOD_M5, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Slow = iMA(_Symbol, PERIOD_M5, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   handleATR = iATR(_Symbol, PERIOD_M5, ATR_Period);
   handleStoch = iStochastic(_Symbol, PERIOD_M5, Stoch_K_Period, Stoch_D_Period, 
                             Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   
   if(handleBB == INVALID_HANDLE || handleRSI == INVALID_HANDLE || 
      handleEMA_Fast == INVALID_HANDLE || handleEMA_Slow == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE || handleStoch == INVALID_HANDLE) {
      Print(">> ERRO: Falha ao criar indicadores!");
      return INIT_FAILED;
   }
   
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   lastDay = tm.day;
   
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   trade.SetAsyncMode(false);
   
   Print("========================================");
   Print("=== Statistical Edge v2 Inicializado ===");
   Print("========================================");
   PrintFormat("Modelos Ativos: BB=%d RSI=%d Struct=%d Stoch=%d",
               UseMeanReversion, UseMomentum, UseStructure, UseStochastic);
   PrintFormat("Pesos: BB=%d RSI=%d Struct=%d Stoch=%d",
               MeanRev_Weight, Momentum_Weight, Structure_Weight, Stochastic_Weight);
   PrintFormat("Votos Necessários: %d (ponderado)", MinVotesRequired);
   PrintFormat("Daily Loss Limit: %.0f pontos", DailyLossLimit);
   Print("========================================");
   
   Sleep(1000);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Execução Principal                                                |
//+------------------------------------------------------------------+
void OnTick() {
   if(!IsNewBar()) {
      if(PositionSelect(_Symbol)) ManagePosition();
      return;
   }
   
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   if(tm.day != lastDay) {
      tradingBlocked = false;
      dailyLossInPoints = 0.0;
      lastDay = tm.day;
   }
   
   // Resetar rastreamento de posição se não há posição aberta
   if(!PositionSelect(_Symbol)) {
      positionOpenTime = 0;
      barsAtPositionOpen = 0;
   } else {
      // Se há posição, gerenciar
      ManagePosition();
   }
   
   if(tradingBlocked || !IsTradingTime()) return;
   
   // Verificar limite de perda diária
   if(!IsWithinDailyLossLimit()) return;
   
   // Filtros básicos
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - 
                    SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spread > MaxSpread) return;
   
   double atr[];
   if(CopyBuffer(handleATR, 0, 1, 1, atr) < 1) return;
   if(atr[0] < ATR_MinMultiplier * _Point) return;
   
   //==========================================================================
   // SISTEMA DE VOTAÇÃO PONDERADO (4 MODELOS)
   //==========================================================================
   
   int signal1 = SignalMeanReversion();
   int signal2 = SignalMomentum();
   int signal3 = SignalStructure();
   int signal4 = SignalStochastic();
   int trendFilter = FilterTrend();
   
   // Soma ponderada dos sinais
   int totalVotes = signal1 + signal2 + signal3 + signal4;
   
   // Log detalhado
   if(signal1 != 0 || signal2 != 0 || signal3 != 0 || signal4 != 0) {
      PrintFormat(">> SINAIS: BB=%+d | RSI=%+d | Struct=%+d | Stoch=%+d | TOTAL=%+d | Trend=%+d",
                  signal1, signal2, signal3, signal4, totalVotes, trendFilter);
   }
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   //==========================================================================
   // REGRAS DE ENTRADA COM VOTOS PONDERADOS
   //==========================================================================
   
   // COMPRA: Votos positivos >= mínimo + tendência favorável
   if(totalVotes >= MinVotesRequired && trendFilter >= 0) {
      double slPoints = CalculateDynamicSL(true);
      double tpPoints = slPoints * RiskRewardRatio;
      
      double slPrice = NormalizePrice(ask - slPoints * _Point);
      double tpPrice = NormalizePrice(ask + tpPoints * _Point);
      
      lotSize = CalculateLotSize(slPoints);
      
      PrintFormat(">> === SETUP COMPRA ===");
      PrintFormat("Votos: %d/%d | Modelos: [%+d,%+d,%+d,%+d]", 
                  totalVotes, MinVotesRequired, signal1, signal2, signal3, signal4);
      PrintFormat("SL=%.0f TP=%.0f R:R=%.2f | Lote=%.2f",
                  slPoints, tpPoints, RiskRewardRatio, lotSize);
      
      if(trade.Buy(lotSize, _Symbol, ask, slPrice, tpPrice)) {
         Print(">> COMPRA EXECUTADA COM SUCESSO");
      } else {
         PrintFormat(">> Erro: %s", trade.ResultRetcodeDescription());
      }
   }
   
   // VENDA: Votos negativos <= -mínimo + tendência favorável
   if(totalVotes <= -MinVotesRequired && trendFilter <= 0) {
      double slPoints = CalculateDynamicSL(false);
      double tpPoints = slPoints * RiskRewardRatio;
      
      double slPrice = NormalizePrice(bid + slPoints * _Point);
      double tpPrice = NormalizePrice(bid - tpPoints * _Point);
      
      lotSize = CalculateLotSize(slPoints);
      
      PrintFormat("=== SETUP VENDA ===");
      PrintFormat("Votos: %d/%d | Modelos: [%+d,%+d,%+d,%+d]", 
                  totalVotes, MinVotesRequired, signal1, signal2, signal3, signal4);
      PrintFormat("SL=%.0f TP=%.0f R:R=%.2f | Lote=%.2f",
                  slPoints, tpPoints, RiskRewardRatio, lotSize);
      
      if(trade.Sell(lotSize, _Symbol, bid, slPrice, tpPrice)) {
         Print(">> VENDA EXECUTADA COM SUCESSO");
      } else {
         PrintFormat(">> Erro: %s", trade.ResultRetcodeDescription());
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans, 
                       const MqlTradeRequest& req, 
                       const MqlTradeResult& res) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal)) {
      long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) {
         double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
         double volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
         
         string result = profit >= 0 ? "> GAIN" : "< LOSS";
         PrintFormat("==============================");
         PrintFormat("TRADE FECHADO: %.2f %s", profit, result);
         PrintFormat("Volume: %.2f | Preço: %.2f", 
                     volume, HistoryDealGetDouble(trans.deal, DEAL_PRICE));
         PrintFormat("==============================");
      }
   }
}