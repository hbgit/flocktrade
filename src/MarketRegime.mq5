//+------------------------------------------------------------------+
//|                       MarketRegime.mq5                 |
//|              Sistema Adaptativo por REGIME DE MERCADO            |
//|                TREND • RANGE • BREAKOUT                          |
//+------------------------------------------------------------------+
#property copyright "hbgit, 2026."
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

// ENUMERADOR DE REGIMES
enum ENUM_MARKET_REGIME {
   REGIME_UNDEFINED = 0,   // Indefinido
   REGIME_TREND = 1,       // Tendência
   REGIME_RANGE = 2,       // Lateralização
   REGIME_BREAKOUT = 3     // Rompimento
};

//============================================================================
// INPUTS - GERENCIAMENTO DE RISCO
//============================================================================

input group "=== GERENCIAMENTO DE RISCO ==="
input double RiskPercent = 1.0;        // Risco por operação (% capital)
input int DailyLossLimit = 250;        // Limite de perda diária (pontos)

input group "=== DETECTOR DE REGIME (NÚCLEO DO EA) ==="
input int Regime_LookbackBars = 20;    // Candles para análise de regime
input double Regime_TrendThreshold = 0.65; // Threshold direcionalidade (0-1)
input double Regime_RangeATRRatio = 0.7;   // ATR baixo para range (× média)
input double Regime_BreakoutATRRatio = 1.3; // ATR alto para breakout (× média)

input group "=== MODELO 1: TREND FOLLOWING ==="
input bool UseTrendModel = true;       // Ativar modelo Trend
input int Trend_EMA_Fast = 9;          // EMA Rápida M5
input int Trend_EMA_Slow = 21;         // EMA Lenta M5
input int Trend_EMA_H1 = 50;           // EMA H1 para viés
input double Trend_ATR_Growth = 0.95;  // ATR crescente (× média) - REDUZIDO de 1.1 para 0.95
input double Trend_RiskReward = 2.0;   // R:R para trend

input group "=== MODELO 2: MEAN REVERSION (RANGE) ==="
input bool UseRangeModel = true;       // Ativar modelo Range
input int Range_BB_Period = 20;        // Bollinger Bands período
input double Range_BB_Deviation = 2.0; // Desvios padrão
input int Range_Stoch_K = 14;          // Stochastic %K
input int Range_Stoch_D = 3;           // Stochastic %D
input int Range_Stoch_Slowing = 3;     // Slowing
input double Range_RiskReward = 1.5;   // R:R para range

input group "=== MODELO 3: BREAKOUT ==="
input bool UseBreakoutModel = true;    // Ativar modelo Breakout
input int Breakout_ConsolidationBars = 15; // Candles de consolidação
input double Breakout_VolumeMultiplier = 1.5; // Volume acima média
input double Breakout_RiskReward = 2.5; // R:R para breakout

input group "=== FILTROS GERAIS ==="
input int ATR_Period = 14;             // Período ATR
input int MaxSpread = 10;              // Spread máximo (pontos)
input double MaxSpreadPercentSL = 20.0; // Spread máximo em % do SL

input group "=== HORÁRIOS ==="
input int StartHour1 = 9;              // Início Manhã - ESTENDIDO de 10 para 9
input int EndHour1 = 13;               // Fim Manhã - ESTENDIDO de 11 para 13
input int StartHour2 = 14;             // Início Tarde
input int EndHour2 = 17;               // Fim Tarde - ESTENDIDO de 16 para 17

input group "=== STOP LOSS DINÂMICO ==="
input double ATR_StopMultiplier = 2.5; // Multiplicador ATR para SL
input int MinStopPoints = 100;         // Stop mínimo (pontos)
input int MaxStopPoints = 300;         // Stop máximo (pontos)

input group "=== GERENCIAMENTO DE POSIÇÃO ==="
input double BreakEvenTrigger = 0.6;   // BE em % do TP (60%)
input double BreakEvenOffset = 0.5;    // Offset do BE (50% lucro)
input double TrailingStart = 0.6;      // Início trailing (60% TP)
input double TrailingStep = 0.3;       // Step trailing (30% movimento)
input int MinDelayBreakEvenBars = 5;   // Delay mínimo para BE (candles)
input int MinDelayTrailingBars = 8;    // Delay mínimo para trailing (candles)
input bool UseParcialExit = true;      // Saída parcial (50% no TP1)

//============================================================================
// VARIÁVEIS GLOBAIS
//============================================================================

// Handles de Indicadores
int handleATR_M5, handleATR_H1;
int handleEMA_Fast_M5, handleEMA_Slow_M5, handleEMA_H1;
int handleBB_M5, handleStoch_M5;

// Controles
double lotSize;
bool tradingBlocked = false;
int lastDay = -1;
static datetime lastBarTime = 0;
double dailyLossInPoints = 0.0;

// Rastreamento de posição
static datetime positionOpenTime = 0;
static int barsAtPositionOpen = 0;
static ENUM_MARKET_REGIME currentRegime = REGIME_UNDEFINED;
static string currentRegimeStr = "INDEFINIDO";

// Aquecimento de indicadores
static int barsLoaded = 0;
const int WARMUP_BARS = 50;  // Número mínimo de barras para aquecimento

//============================================================================
// FUNÇÕES MATEMÁTICAS E UTILITÁRIAS
//============================================================================

double NormalizePrice(double price) {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

bool ValidateStops(bool isBuy, double entryPrice, double slPrice, double tpPrice) {
   // Obter nível mínimo de stop da corretora
   int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopLevel * _Point;
   
   if(stopLevel > 0) {
      if(isBuy) {
         // Para compra: SL deve estar abaixo e TP acima
         if((entryPrice - slPrice) < minDistance) {
            PrintFormat(">> ERRO: SL muito próximo. Dist=%.5f Min=%.5f", (entryPrice - slPrice), minDistance);
            return false;
         }
         if((tpPrice - entryPrice) < minDistance) {
            PrintFormat(">> ERRO: TP muito próximo. Dist=%.5f Min=%.5f", (tpPrice - entryPrice), minDistance);
            return false;
         }
      } else {
         // Para venda: SL deve estar acima e TP abaixo
         if((slPrice - entryPrice) < minDistance) {
            PrintFormat(">> ERRO: SL muito próximo. Dist=%.5f Min=%.5f", (slPrice - entryPrice), minDistance);
            return false;
         }
         if((entryPrice - tpPrice) < minDistance) {
            PrintFormat(">> ERRO: TP muito próximo. Dist=%.5f Min=%.5f", (entryPrice - tpPrice), minDistance);
            return false;
         }
      }
   }
   
   // Validar que SL e TP não são zero e têm sentido
   if(slPrice <= 0 || tpPrice <= 0) {
      PrintFormat(">> ERRO: SL ou TP inválido. SL=%.5f TP=%.5f", slPrice, tpPrice);
      return false;
   }
   
   return true;
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
//| NÚCLEO: DETECTOR DE REGIME DE MERCADO                            |
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME DetectMarketRegime() {
   double atr_m5[];
   double high[], low[], close[];
   
   // Validação: Número mínimo de barras carregadas
   int bars = iBars(_Symbol, PERIOD_M5);
   if(bars < Regime_LookbackBars + 10) {
      PrintFormat(">> Dados insuficientes. Barras disponíveis: %d / Necessárias: %d", 
                  bars, Regime_LookbackBars + 10);
      return REGIME_UNDEFINED;
   }
   
   // Obter ATR para volatilidade
   if(CopyBuffer(handleATR_M5, 0, 1, Regime_LookbackBars, atr_m5) < Regime_LookbackBars) {
      PrintFormat(">> Erro ao copiar ATR. Retornou: %d / Esperado: %d", 
                  CopyBuffer(handleATR_M5, 0, 1, Regime_LookbackBars, atr_m5), 
                  Regime_LookbackBars);
      return REGIME_UNDEFINED;
   }
   
   // Calcular ATR médio
   double atr_avg = 0;
   for(int i = 0; i < Regime_LookbackBars; i++) {
      if(atr_m5[i] <= 0) {
         PrintFormat(">> ATR inválido no índice %d: %.5f", i, atr_m5[i]);
         return REGIME_UNDEFINED;
      }
      atr_avg += atr_m5[i];
   }
   atr_avg /= Regime_LookbackBars;
   
   double atr_current = atr_m5[Regime_LookbackBars-1];
   
   // Obter dados de preço
   if(CopyHigh(_Symbol, PERIOD_M5, 1, Regime_LookbackBars, high) < Regime_LookbackBars) {
      PrintFormat(">> Erro ao copiar HIGH");
      return REGIME_UNDEFINED;
   }
   if(CopyLow(_Symbol, PERIOD_M5, 1, Regime_LookbackBars, low) < Regime_LookbackBars) {
      PrintFormat(">> Erro ao copiar LOW");
      return REGIME_UNDEFINED;
   }
   if(CopyClose(_Symbol, PERIOD_M5, 1, Regime_LookbackBars, close) < Regime_LookbackBars) {
      PrintFormat(">> Erro ao copiar CLOSE");
      return REGIME_UNDEFINED;
   }
   
   // 1. DETECTAR BREAKOUT: ATR expandindo + range rompido
   double maxHigh = high[ArrayMaximum(high)];
   double minLow = low[ArrayMinimum(low)];
   double rangeSize = maxHigh - minLow;
   double currentClose = close[Regime_LookbackBars-1];
   
   if(rangeSize <= 0) {
      PrintFormat(">> Range inválido: %.5f", rangeSize);
      return REGIME_UNDEFINED;
   }
   
   if(atr_current > atr_avg * Regime_BreakoutATRRatio) {
      // ATR alto - verificar se há rompimento
      if(currentClose > maxHigh - rangeSize * 0.2 || currentClose < minLow + rangeSize * 0.2) {
         currentRegimeStr = "BREAKOUT";
         PrintFormat(">> REGIME DETECTADO: BREAKOUT (ATR=%.0f > Média=%.0f * %.2f)", 
                     atr_current, atr_avg, Regime_BreakoutATRRatio);
         return REGIME_BREAKOUT;
      }
   }
   
   // 2. DETECTAR RANGE: ATR baixo + preço oscilando
   if(atr_current < atr_avg * Regime_RangeATRRatio) {
      // Verificar oscilação: preço não deve estar em tendência clara
      int upmoves = 0, downmoves = 0;
      for(int i = 1; i < Regime_LookbackBars; i++) {
         if(close[i] > close[i-1]) upmoves++;
         else if(close[i] < close[i-1]) downmoves++;
      }
      
      double directionality = MathAbs(upmoves - downmoves) / (double)Regime_LookbackBars;
      if(directionality < Regime_TrendThreshold) {
         currentRegimeStr = "RANGE";
         PrintFormat(">> REGIME DETECTADO: RANGE (ATR=%.0f < Média=%.0f * %.2f, Direcionalidade=%.2f)", 
                     atr_current, atr_avg, Regime_RangeATRRatio, directionality);
         return REGIME_RANGE;
      }
   }
   
   // 3. DETECTAR TREND: Direcionalidade clara
   double ema_fast[], ema_slow[];
   if(CopyBuffer(handleEMA_Fast_M5, 0, 1, 10, ema_fast) < 10) {
      PrintFormat(">> Erro ao copiar EMA Fast");
      return REGIME_UNDEFINED;
   }
   if(CopyBuffer(handleEMA_Slow_M5, 0, 1, 10, ema_slow) < 10) {
      PrintFormat(">> Erro ao copiar EMA Slow");
      return REGIME_UNDEFINED;
   }
   
   // EMAs consistentemente alinhadas
   bool trendUp = true, trendDown = true;
   for(int i = 0; i < 10; i++) {
      if(ema_fast[i] <= ema_slow[i]) trendUp = false;
      if(ema_fast[i] >= ema_slow[i]) trendDown = false;
   }
   
   if(trendUp || trendDown) {
      // Confirmar com ATR crescente
      if(atr_current >= atr_avg * Trend_ATR_Growth) {
         currentRegimeStr = "TREND";
         PrintFormat(">> REGIME DETECTADO: TREND (ATR=%.0f >= Média=%.0f * %.2f, %s)", 
                     atr_current, atr_avg, Trend_ATR_Growth, trendUp ? "UP" : "DOWN");
         return REGIME_TREND;
      }
   }
   
   currentRegimeStr = "INDEFINIDO";
   return REGIME_UNDEFINED;
}

//+------------------------------------------------------------------+
//| MODELO 1: TREND FOLLOWING                                        |
//+------------------------------------------------------------------+
int SignalTrendFollowing() {
   if(!UseTrendModel || currentRegime != REGIME_TREND) return 0;
   
   double ema_fast[], ema_slow[], ema_h1[];
   double atr_current[], atr_prev[];
   
   // EMAs M5
   if(CopyBuffer(handleEMA_Fast_M5, 0, 1, 3, ema_fast) < 3) {
      PrintFormat(">> [TREND DEBUG] Erro ao copiar EMA_Fast");
      return 0;
   }
   if(CopyBuffer(handleEMA_Slow_M5, 0, 1, 3, ema_slow) < 3) {
      PrintFormat(">> [TREND DEBUG] Erro ao copiar EMA_Slow");
      return 0;
   }
   
   // EMA H1 para viés
   if(CopyBuffer(handleEMA_H1, 0, 0, 1, ema_h1) < 1) {
      PrintFormat(">> [TREND DEBUG] Erro ao copiar EMA_H1");
      return 0;
   }
   
   // ATR crescente - usar 20 barras como em DetectMarketRegime() para consistência
   if(CopyBuffer(handleATR_M5, 0, 1, 20, atr_current) < 20) {
      PrintFormat(">> [TREND DEBUG] Erro ao copiar ATR");
      return 0;
   }
   
   // ⚠️ CRÍTICO: Índices corretos para valores ATUAIS (mais recentes)
   // Averaged over 20 bars like DetectMarketRegime() for consistency
   // atr_current[0] = bar 1 (antigo), atr_current[19] = bar 20 (atual/recente)
   double atr_now = atr_current[19];      // ✅ ATR mais recente (bar 20)
   double atr_avg = 0;
   for(int i = 0; i < 20; i++) atr_avg += atr_current[i];  // ✅ Média dos 20 últimos
   atr_avg /= 20;
   
   double close_now = iClose(_Symbol, PERIOD_M5, 1);
   
   PrintFormat(">> [TREND DEBUG] EMA9[2]=%.5f EMA21[2]=%.5f | ATR=%.0f(%.0f*%.2f) | Close=%.5f EMA_H1=%.5f", 
               ema_fast[2], ema_slow[2], atr_now, atr_avg, Trend_ATR_Growth, close_now, ema_h1[0]);
   
   // SINAL DE COMPRA: EMA9 > EMA21 + ATR crescente + acima EMA H1
   if(ema_fast[2] > ema_slow[2] && ema_fast[1] > ema_slow[1] && 
      atr_now > atr_avg * Trend_ATR_Growth &&
      close_now > ema_h1[0]) {
      PrintFormat(">> [TREND SIGNAL] COMPRA: EMA9>EMA21 AND ATR crescendo AND Close>EMA_H1");
      return +1;  // Compra Trend
   }
   
   // SINAL DE VENDA: EMA9 < EMA21 + ATR crescente + abaixo EMA H1
   if(ema_fast[2] < ema_slow[2] && ema_fast[1] < ema_slow[1] && 
      atr_now > atr_avg * Trend_ATR_Growth &&
      close_now < ema_h1[0]) {
      PrintFormat(">> [TREND SIGNAL] VENDA: EMA9<EMA21 AND ATR crescendo AND Close<EMA_H1");
      return -1;  // Venda Trend
   }
   
   PrintFormat(">> [TREND DEBUG] Nenhum sinal: EMA9>EMA21? %s | ATR crescendo? %s | Close>EMA_H1? %s",
               (ema_fast[2] > ema_slow[2] ? "SIM" : "NÃO"),
               (atr_now > atr_avg * Trend_ATR_Growth ? "SIM" : "NÃO"),
               (close_now > ema_h1[0] ? "SIM" : "NÃO"));
   
   return 0;
}

//+------------------------------------------------------------------+
//| MODELO 2: MEAN REVERSION (RANGE)                                 |
//+------------------------------------------------------------------+
int SignalMeanReversion() {
   if(!UseRangeModel || currentRegime != REGIME_RANGE) return 0;
   
   double bb_upper[], bb_lower[], bb_middle[];
   double stoch_k[], stoch_d[];
   double high[], low[], close[];
   
   // Bollinger Bands
   if(CopyBuffer(handleBB_M5, 1, 1, 2, bb_upper) < 2) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar BB Upper");
      return 0;
   }
   if(CopyBuffer(handleBB_M5, 2, 1, 2, bb_lower) < 2) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar BB Lower");
      return 0;
   }
   if(CopyBuffer(handleBB_M5, 0, 1, 2, bb_middle) < 2) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar BB Middle");
      return 0;
   }
   
   // Stochastic
   if(CopyBuffer(handleStoch_M5, 0, 1, 3, stoch_k) < 3) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar Stoch K");
      return 0;
   }
   if(CopyBuffer(handleStoch_M5, 1, 1, 3, stoch_d) < 3) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar Stoch D");
      return 0;
   }
   
   // Dados de preço
   if(CopyHigh(_Symbol, PERIOD_M5, 1, 2, high) < 2) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar HIGH");
      return 0;
   }
   if(CopyLow(_Symbol, PERIOD_M5, 1, 2, low) < 2) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar LOW");
      return 0;
   }
   if(CopyClose(_Symbol, PERIOD_M5, 1, 2, close) < 2) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar CLOSE");
      return 0;
   }
   
   // ⚠️ CRÍTICO: Índices corretos para valores ATUAIS (mais recentes)
   // CopyBuffer(..., 1, 2, array) = array[0] = bar 1 (antigo), array[1] = bar 2 (atual/recente)
   // CopyBuffer(..., 1, 3, stoch) = stoch[0] = bar 1, stoch[1] = bar 2, stoch[2] = bar 3 (atual/recente)
   
   double bb_upper_now = bb_upper[1];    // ✅ Banda superior atual
   double bb_lower_now = bb_lower[1];    // ✅ Banda inferior atual
   double bb_middle_now = bb_middle[1];  // ✅ Banda média atual
   double high_now = high[1];            // ✅ High atual
   double low_now = low[1];              // ✅ Low atual
   double close_now = close[1];          // ✅ Close atual
   
   // Mean Reversion Strategy for WIN M5 RANGE:
   // Opera quando preço está afastado da média (mínimo 10% do band_range)
   double band_range = bb_upper_now - bb_lower_now;
   double distance_from_middle = close_now - bb_middle_now;
   double min_distance_threshold = band_range * 0.10;  // 10% do range
   
   PrintFormat(">> [RANGE DEBUG] BBupper=%.5f BBmiddle=%.5f BBlower=%.5f | High=%.5f Low=%.5f Close=%.5f", 
               bb_upper_now, bb_middle_now, bb_lower_now, high_now, low_now, close_now);
   PrintFormat(">> [RANGE DEBUG] Distância: %.0f | Threshold mín: %.0f | Close < Média-10%%? %s | Close > Média+10%%? %s",
               MathAbs(distance_from_middle), min_distance_threshold,
               (close_now < bb_middle_now - min_distance_threshold ? "SIM" : "NÃO"),
               (close_now > bb_middle_now + min_distance_threshold ? "SIM" : "NÃO"));
   
   // COMPRA: Close ABAIXO da média (mín 10%) + rejeição bullish
   if(close_now < bb_middle_now - min_distance_threshold && close_now > low_now) {
      PrintFormat(">> Sinal RANGE BUY: Close=%.5f < Média-10%%=%.5f (dist=%.0f) + rejeição", 
                  close_now, bb_middle_now - min_distance_threshold, MathAbs(distance_from_middle));
      return +1;
   }
   
   // VENDA: Close ACIMA da média (mín 10%) + rejeição bearish
   if(close_now > bb_middle_now + min_distance_threshold && close_now < high_now) {
      PrintFormat(">> Sinal RANGE SELL: Close=%.5f > Média+10%%=%.5f (dist=%.0f) + rejeição", 
                  close_now, bb_middle_now + min_distance_threshold, MathAbs(distance_from_middle));
      return -1;
   }
   
   PrintFormat(">> [RANGE DEBUG] Nenhum sinal gerado");
   
   return 0;
}

//+------------------------------------------------------------------+
//| MODELO 3: BREAKOUT                                               |
//+------------------------------------------------------------------+
int SignalBreakout() {
   if(!UseBreakoutModel || currentRegime != REGIME_BREAKOUT) return 0;
   
   double high[], low[], close[];
   double atr[];
   
   // Dados de consolidação
   if(CopyHigh(_Symbol, PERIOD_M5, 1, Breakout_ConsolidationBars + 1, high) < Breakout_ConsolidationBars + 1) {
      PrintFormat(">> Erro ao copiar HIGH para Breakout");
      return 0;
   }
   if(CopyLow(_Symbol, PERIOD_M5, 1, Breakout_ConsolidationBars + 1, low) < Breakout_ConsolidationBars + 1) {
      PrintFormat(">> Erro ao copiar LOW para Breakout");
      return 0;
   }
   if(CopyClose(_Symbol, PERIOD_M5, 1, Breakout_ConsolidationBars + 1, close) < Breakout_ConsolidationBars + 1) {
      PrintFormat(">> Erro ao copiar CLOSE para Breakout");
      return 0;
   }
   
   // ATR
   if(CopyBuffer(handleATR_M5, 0, 1, Breakout_ConsolidationBars, atr) < Breakout_ConsolidationBars) {
      PrintFormat(">> Erro ao copiar ATR para Breakout");
      return 0;
   }
   
   // Volume - usar CopyTickVolume com tratamento de erro
   long volume[];
   if(CopyTickVolume(_Symbol, PERIOD_M5, 1, Breakout_ConsolidationBars + 1, volume) < Breakout_ConsolidationBars + 1) {
      PrintFormat(">> Aviso: Volume indisponível para Breakout, usando apenas preço e ATR");
      // Continuar sem volume
   }
   
   // Calcular range de consolidação (excluindo o candle atual)
   double maxHigh = high[1];
   double minLow = low[1];
   for(int i = 2; i <= Breakout_ConsolidationBars; i++) {
      if(high[i] > maxHigh) maxHigh = high[i];
      if(low[i] < minLow) minLow = low[i];
   }
   
   double rangeSize = maxHigh - minLow;
   
   // ATR médio - usar índices corretos (0 é candle 1, 14 é candle 15)
   double avgATR = 0;
   for(int i = 0; i < Breakout_ConsolidationBars; i++) {
      if(atr[i] <= 0) {
         PrintFormat(">> ATR inválido em Breakout no índice %d: %.5f", i, atr[i]);
         return 0;
      }
      avgATR += atr[i];
   }
   avgATR /= Breakout_ConsolidationBars;
   
   // ⚠️ CRÍTICO: Índices corretos para candle ATUAL (mais recente)
   // close[0] = candle 1 (antigo), close[15] = candle 16 (atual/recente)
   // atr[0] = candle 1 (antigo), atr[14] = candle 15 (atual/recente)
   double currentClose = close[Breakout_ConsolidationBars];    // ✅ Último candle (mais recente)
   double currentATR = atr[Breakout_ConsolidationBars - 1];     // ✅ Último candle ATR (mais recente)
   
   // Volume médio (se disponível)
   double avgVolume = 1.0;  // Default 1.0 se não houver volume
   bool volumeAvailable = false;
   if(ArraySize(volume) > 0) {
      avgVolume = 0;
      for(int i = 1; i <= Breakout_ConsolidationBars; i++) {
         if(volume[i] > 0) avgVolume += volume[i];
      }
      avgVolume /= Breakout_ConsolidationBars;
      if(avgVolume > 0) volumeAvailable = true;
      if(avgVolume <= 0) avgVolume = 1.0;
   }
   
   double currentVolume = ArraySize(volume) > 0 ? volume[Breakout_ConsolidationBars] : 1.0;  // ✅ Corrigido
   
   PrintFormat(">> [BREAKOUT DEBUG] Close=%.5f (idx:%d) | MaxHigh=%.5f | MinLow=%.5f | Range=%.0f | ATR=%.0f(Avg=%.0f) | Vol=%.0f(Avg=%.0f Avail:%s)",
               currentClose, Breakout_ConsolidationBars, maxHigh, minLow, rangeSize, currentATR, avgATR, currentVolume, avgVolume, volumeAvailable ? "SIM" : "NÃO");
   
   // COMPRA: Rompimento acima (Close próximo ou acima do MaxHigh)
   if(currentClose > maxHigh - rangeSize * 0.15 && currentATR > avgATR) {
      PrintFormat(">> Sinal BREAKOUT UP: Close=%.5f próximo MaxHigh=%.5f (dentro 15%%) | ATR=%.0f > Média=%.0f | Volume: %.0f", 
                  currentClose, maxHigh, currentATR, avgATR, currentVolume);
      
      // Se volume está disponível, verificar multiplicador; senão aceitar o sinal
      if(!volumeAvailable || currentVolume > avgVolume * Breakout_VolumeMultiplier) {
         return +1;  // Compra Breakout
      } else {
         PrintFormat(">> Volume insuficiente: %.0f <= %.0f * %.2f", currentVolume, avgVolume, Breakout_VolumeMultiplier);
      }
   }
   
   // VENDA: Rompimento abaixo (Close próximo ou abaixo do MinLow)
   if(currentClose < minLow + rangeSize * 0.15 && currentATR > avgATR) {
      PrintFormat(">> Sinal BREAKOUT DOWN: Close=%.5f próximo MinLow=%.5f (dentro 15%%) | ATR=%.0f > Média=%.0f | Volume: %.0f", 
                  currentClose, minLow, currentATR, avgATR, currentVolume);
      
      // Se volume está disponível, verificar multiplicador; senão aceitar o sinal
      if(!volumeAvailable || currentVolume > avgVolume * Breakout_VolumeMultiplier) {
         return -1;  // Venda Breakout
      } else {
         PrintFormat(">> Volume insuficiente: %.0f <= %.0f * %.2f", currentVolume, avgVolume, Breakout_VolumeMultiplier);
      }
   }
   
   PrintFormat(">> [BREAKOUT DEBUG] Sem sinal: Close>Max-15%%? %s | Close<Min+15%%? %s | ATR>Avg? %s",
               (currentClose > maxHigh - rangeSize * 0.15 ? "SIM" : "NÃO"),
               (currentClose < minLow + rangeSize * 0.15 ? "SIM" : "NÃO"),
               (currentATR > avgATR ? "SIM" : "NÃO"));
   
   return 0;
}

//+------------------------------------------------------------------+
//| Calcula Stop Loss e TP baseado no Regime                         |
//+------------------------------------------------------------------+
void CalculateStopAndTP(bool isBuy, double &slPoints, double &tpPoints, double &riskReward) {
   double atr[];
   if(CopyBuffer(handleATR_M5, 0, 1, 1, atr) < 1) {
      slPoints = 150;
      tpPoints = 300;
      riskReward = 2.0;
      return;
   }
   
   double atr_value = atr[0] / _Point;
   
   switch(currentRegime) {
      case REGIME_TREND: {
         // Stop: ATR × 2.5 ou último fundo/topo
         slPoints = atr_value * ATR_StopMultiplier;
         riskReward = Trend_RiskReward;
         tpPoints = slPoints * riskReward;
         break;
      }
         
      case REGIME_RANGE: {
         // Stop: Fora da banda
         double bb_upper[], bb_lower[];
         if(CopyBuffer(handleBB_M5, 1, 1, 1, bb_upper) >= 1 && 
            CopyBuffer(handleBB_M5, 2, 1, 1, bb_lower) >= 1) {
            double bb_middle[];
            CopyBuffer(handleBB_M5, 0, 1, 1, bb_middle);
            double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
            slPoints = MathAbs(price - (isBuy ? bb_lower[0] : bb_upper[0])) / _Point * 1.2;
            riskReward = Range_RiskReward;
            tpPoints = slPoints * riskReward;  // TP na média ou VWAP
         } else {
            slPoints = atr_value * 2.0;
            riskReward = Range_RiskReward;
            tpPoints = slPoints * riskReward;
         }
         break;
      }
         
      case REGIME_BREAKOUT: {
         // Stop: Dentro do range rompido
         slPoints = atr_value * 2.0;
         riskReward = Breakout_RiskReward;
         tpPoints = slPoints * riskReward;
         break;
      }
         
      default: {
         slPoints = atr_value * ATR_StopMultiplier;
         riskReward = 2.0;
         tpPoints = slPoints * riskReward;
         break;
      }
   }
   
   // Limites de segurança
   slPoints = MathMax(MinStopPoints, MathMin(MaxStopPoints, slPoints));
   tpPoints = slPoints * riskReward;
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
   // Indicadores M5
   handleATR_M5 = iATR(_Symbol, PERIOD_M5, ATR_Period);
   handleEMA_Fast_M5 = iMA(_Symbol, PERIOD_M5, Trend_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA_Slow_M5 = iMA(_Symbol, PERIOD_M5, Trend_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   handleBB_M5 = iBands(_Symbol, PERIOD_M5, Range_BB_Period, 0, Range_BB_Deviation, PRICE_CLOSE);
   handleStoch_M5 = iStochastic(_Symbol, PERIOD_M5, Range_Stoch_K, Range_Stoch_D, 
                                Range_Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   
   // Indicadores H1
   handleEMA_H1 = iMA(_Symbol, PERIOD_H1, Trend_EMA_H1, 0, MODE_EMA, PRICE_CLOSE);
   handleATR_H1 = iATR(_Symbol, PERIOD_H1, ATR_Period);
   
   if(handleATR_M5 == INVALID_HANDLE || handleEMA_Fast_M5 == INVALID_HANDLE || 
      handleEMA_Slow_M5 == INVALID_HANDLE || handleBB_M5 == INVALID_HANDLE ||
      handleStoch_M5 == INVALID_HANDLE || handleEMA_H1 == INVALID_HANDLE ||
      handleATR_H1 == INVALID_HANDLE) {
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
   Print("=== MarketRegime v1.0 ===");
   Print("========================================");
   PrintFormat("Modelos Ativos:");
   PrintFormat(" - TREND Following: %s", UseTrendModel ? "SIM" : "NÃO");
   PrintFormat(" - RANGE Reversion: %s", UseRangeModel ? "SIM" : "NÃO");
   PrintFormat(" - BREAKOUT: %s", UseBreakoutModel ? "SIM" : "NÃO");
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
   
   // Incrementar contador de barras carregadas (para aquecimento de indicadores)
   barsLoaded++;
   if(barsLoaded <= WARMUP_BARS) {
      PrintFormat(">> Aquecimento: %d/%d barras carregadas", barsLoaded, WARMUP_BARS);
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
   
   if(tradingBlocked) {
      PrintFormat(">> [FILTER] Trading BLOQUEADO (limite de perda diário atingido)");
      return;
   }
   
   if(!IsTradingTime()) {
      MqlDateTime tm;
      TimeToStruct(TimeCurrent(), tm);
      //PrintFormat(">> [FILTER] Fora do horário de trading (Hora: %02d:%02d)", tm.hour, tm.min);
      return;
   }
   
   // Verificar limite de perda diária
   if(!IsWithinDailyLossLimit()) {
      PrintFormat(">> [FILTER] Limite de perda diária atingido");
      return;
   }
   
   // Filtros básicos
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - 
                    SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spread > MaxSpread) {
      PrintFormat(">> [FILTER] Spread muito alto: %.0f > %.0f", spread, MaxSpread);
      return;
   }
   
   //==========================================================================
   // NÚCLEO: DETECTAR REGIME DE MERCADO
   //==========================================================================
   
   currentRegime = DetectMarketRegime();
   
   // Log do regime detectado
   static ENUM_MARKET_REGIME lastRegime = REGIME_UNDEFINED;
   if(currentRegime != lastRegime) {
      PrintFormat("========================================");
      PrintFormat("REGIME DETECTADO: %s", currentRegimeStr);
      PrintFormat("========================================");
      lastRegime = currentRegime;
   }
   
   if(currentRegime == REGIME_UNDEFINED) {
      return;
   }
   
   //==========================================================================
   // EXECUTAR MODELO ESPECÍFICO DO REGIME
   //==========================================================================
   
   int signal = 0;
   string modelName = "";
   
   switch(currentRegime) {
      case REGIME_TREND:
         signal = SignalTrendFollowing();
         modelName = "TREND FOLLOWING";
         break;
         
      case REGIME_RANGE:
         signal = SignalMeanReversion();
         modelName = "MEAN REVERSION";
         break;
         
      case REGIME_BREAKOUT:
         signal = SignalBreakout();
         modelName = "BREAKOUT";
         break;
   }
   
   if(signal == 0) return;
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   //==========================================================================
   // EXECUTAR ENTRADA
   //==========================================================================
   
   if(signal > 0) {  // COMPRA
      double slPoints, tpPoints, riskReward;
      CalculateStopAndTP(true, slPoints, tpPoints, riskReward);
      
      if(!IsSpreadAcceptable(slPoints)) {
         PrintFormat(">> [FILTER] Spread inaceitável para SL de %.0f pts", slPoints);
         return;
      }
      
      double slPrice = NormalizePrice(ask - slPoints * _Point);
      double tpPrice = NormalizePrice(ask + tpPoints * _Point);
      
      PrintFormat(">> [VALIDATE] COMPRA: ask=%.5f | slPoints=%.0f (slPrice=%.5f) | tpPoints=%.0f (tpPrice=%.5f)", 
                  ask, slPoints, slPrice, tpPoints, tpPrice);
      
      // Validar stops antes de enviar ordem
      if(!ValidateStops(true, ask, slPrice, tpPrice)) {
         PrintFormat(">> Ordem COMPRA cancelada: stops inválidos");
         return;
      }
      
      lotSize = CalculateLotSize(slPoints);
      
      PrintFormat("========================================");
      PrintFormat(">>> SETUP COMPRA <<<");
      PrintFormat("Regime: %s | Modelo: %s", currentRegimeStr, modelName);
      PrintFormat("SL=%.0f pts | TP=%.0f pts | R:R=%.2f", slPoints, tpPoints, riskReward);
      PrintFormat("Ask=%.5f | SL Price=%.5f | TP Price=%.5f", ask, slPrice, tpPrice);
      PrintFormat("Lote=%.2f | Spread=%.0f pts", lotSize, spread);
      PrintFormat("========================================");
      
      if(trade.Buy(lotSize, _Symbol, ask, slPrice, tpPrice)) {
         Print(">> COMPRA EXECUTADA COM SUCESSO");
      } else {
         PrintFormat(">> Erro: %s (code: %d)", trade.ResultRetcodeDescription(), trade.ResultRetcode());
         PrintFormat(">> Debug: ask=%.5f sl=%.5f tp=%.5f", ask, slPrice, tpPrice);
      }
   }
   else if(signal < 0) {  // VENDA
      double slPoints, tpPoints, riskReward;
      CalculateStopAndTP(false, slPoints, tpPoints, riskReward);
      
      if(!IsSpreadAcceptable(slPoints)) {
         PrintFormat(">> [FILTER] Spread inaceitável para SL de %.0f pts", slPoints);
         return;
      }
      
      double slPrice = NormalizePrice(bid + slPoints * _Point);
      double tpPrice = NormalizePrice(bid - tpPoints * _Point);
      
      PrintFormat(">> [VALIDATE] VENDA: bid=%.5f | slPoints=%.0f (slPrice=%.5f) | tpPoints=%.0f (tpPrice=%.5f)", 
                  bid, slPoints, slPrice, tpPoints, tpPrice);
      
      // Validar stops antes de enviar ordem
      if(!ValidateStops(false, bid, slPrice, tpPrice)) {
         PrintFormat(">> Ordem VENDA cancelada: stops inválidos");
         return;
      }
      
      lotSize = CalculateLotSize(slPoints);
      
      PrintFormat("========================================");
      PrintFormat(">>> SETUP VENDA <<<");
      PrintFormat("Regime: %s | Modelo: %s", currentRegimeStr, modelName);
      PrintFormat("SL=%.0f pts | TP=%.0f pts | R:R=%.2f", slPoints, tpPoints, riskReward);
      PrintFormat("Bid=%.5f | SL Price=%.5f | TP Price=%.5f", bid, slPrice, tpPrice);
      PrintFormat("Lote=%.2f | Spread=%.0f pts", lotSize, spread);
      PrintFormat("========================================");
      
      if(trade.Sell(lotSize, _Symbol, bid, slPrice, tpPrice)) {
         Print(">> VENDA EXECUTADA COM SUCESSO");
      } else {
         PrintFormat(">> Erro: %s (code: %d)", trade.ResultRetcodeDescription(), trade.ResultRetcode());
         PrintFormat(">> Debug: bid=%.5f sl=%.5f tp=%.5f", bid, slPrice, tpPrice);
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