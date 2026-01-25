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
input double Regime_TrendThreshold = 0.75; // Threshold direcionalidade (0-1)
input double Regime_RangeATRRatio = 0.7;   // ATR baixo para range (× média)
input double Regime_BreakoutATRRatio = 1.3; // ATR alto para breakout (× média)

input group "=== MODELO 1: TREND FOLLOWING ==="
input bool UseTrendModel = true;       // Ativar modelo Trend
input int Trend_EMA_Fast = 9;          // EMA Rápida M5
input int Trend_EMA_Slow = 21;         // EMA Lenta M5
input int Trend_EMA_H1 = 50;           // EMA H1 para viés
input double Trend_ATR_Growth = 0.95;  // ATR crescente (× média) - REDUZIDO de 1.1 para 0.95
input double Trend_RiskReward = 2.0;   // R:R para trend
input double Trend_ADX_Threshold = 25.0; // ADX mínimo para trend (força do trend)

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
input int StartHour1 = 10;              // Início Manhã
input int EndHour1 = 13;               // Fim Manhã
input int StartHour2 = 14;             // Início Tarde
input int EndHour2 = 17;               // Fim Tarde

input group "=== STOP LOSS DINÂMICO ==="
input double ATR_StopMultiplier = 2.5; // Multiplicador ATR para SL
input int MinStopPoints = 100;         // Stop mínimo (pontos)
input int MaxStopPoints = 300;         // Stop máximo (pontos)

input group "=== GERENCIAMENTO DE POSIÇÃO ==="
input double BreakEvenTrigger = 0.3;   // BE em % do TP (30%)
input double BreakEvenOffset = 0.5;    // Offset do BE (50% lucro)
input double TrailingStart = 0.3;      // Início trailing (30% TP)
input double TrailingStep = 0.3;       // Step trailing (30% movimento)
input int MinDelayBreakEvenBars = 5;   // Delay mínimo para BE (candles)
input int MinDelayTrailingBars = 8;    // Delay mínimo para trailing (candles)
input bool UseParcialExit = true;      // Saída parcial (50% no TP1)

input group "=== CONTROLE DE FLUXO ==="
input bool UseOneTradePerBar = true;   // Uma operação por candle
input int CooldownMinutesAfterSL = 15; // Tempo de espera após Stop Loss (minutos)
input bool UseDirectionCooldown = true; // Impedir mesma direção após SL

//============================================================================
// VARIÁVEIS GLOBAIS
//============================================================================

// Handles de Indicadores
int handleATR_M5, handleATR_H1;
int handleEMA_Fast_M5, handleEMA_Slow_M5, handleEMA_H1;
int handleBB_M5, handleStoch_M5;
int handleADX_M5;  // Handle para ADX no timeframe M5

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

// Controle de Fluxo - OneTradePerBar
static datetime lastTradeBarTime = 0;  // Timestamp do candle do último trade executado

// Controle de Fluxo - Cooldown após Stop Loss
static datetime lastStopLossTime = 0;  // Momento do último stop loss
static int lastStopLossDirection = 0;  // Direção do último stop loss (+1 compra, -1 venda, 0 nenhum)

// Controle de Fluxo - BREAKOUT com Pullback
static bool breakoutConfirmed = false;      // Flag: breakout detectado, aguardando pullback
static int breakoutDirection = 0;           // Direção do breakout (+1 = up, -1 = down, 0 = nenhum)
static double breakoutLevel = 0;            // Nível do breakout (MaxHigh ou MinLow)
static double breakoutATR = 0;              // ATR no momento do breakout (para cálculo de pullback)
static int breakoutPullbackAttempts = 0;    // Contador de tentativas de entrada no pullback (máx 1)

// Controle de Fluxo - TREND com Pullback
static bool trendSignalConfirmed = false;   // Flag: sinal TREND detectado, aguardando pullback até EMA
static int trendSignalDirection = 0;        // Direção do sinal (+1 compra, -1 venda, 0 = nenhum)
static double trendSignalEMA9Level = 0;     // Nível da EMA9 no momento do sinal
static double trendSignalEMA21Level = 0;    // Nível da EMA21 no momento do sinal

// Controle de Fechamento Mínimo
static bool minClosureProfitReached = false; // Flag: lucro mínimo de fechamento atingido
static int trendPullbackAttempts = 0;       // Contador de tentativas de entrada (máx 1)

// Controle de Trades Consecutivos - TREND
static int trendTrades = 0;                 // Contador de trades TREND consecutivos (máx 2)

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

//+------------------------------------------------------------------+
//| Calcula Lucro Mínimo de Fechamento                               |
//+------------------------------------------------------------------+
double CalculateMinClosureProfit() {
   double atr[];
   if(CopyBuffer(handleATR_M5, 0, 1, 1, atr) < 1) {
      return 20 * _Point;  // Fallback se falhar em copiar ATR
   }
   
   double atrValue = atr[0];
   double operationalMinimum = 20 * _Point;
   double volatilityAdaptation = atrValue * 0.25;
   
   return MathMax(operationalMinimum, volatilityAdaptation);
}

//+------------------------------------------------------------------+
//| Valida se a Posição Atingiu Lucro Mínimo de Fechamento           |
//+------------------------------------------------------------------+
bool HasReachedMinClosureProfit(bool isBuy, double currentPrice, double openPrice) {
   double minClosureProfit = CalculateMinClosureProfit();
   double currentProfit = 0;
   
   if(isBuy) {
      currentProfit = (currentPrice - openPrice) / _Point;
   } else {
      currentProfit = (openPrice - currentPrice) / _Point;
   }
   
   double minClosureProfitPoints = minClosureProfit / _Point;
   
   PrintFormat(">> [MIN CLOSURE] Lucro Atual: %.2f pts | Mínimo Requerido: %.2f pts", 
               currentProfit, minClosureProfitPoints);
   
   return currentProfit >= minClosureProfitPoints;
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
   double adx[], adx_average[];
   
   // EMAs M5 - coletar 6 períodos para calcular slope (EMA[0] - EMA[3])
   if(CopyBuffer(handleEMA_Fast_M5, 0, 1, 6, ema_fast) < 6) {
      PrintFormat(">> [TREND DEBUG] Erro ao copiar EMA_Fast");
      return 0;
   }
   if(CopyBuffer(handleEMA_Slow_M5, 0, 1, 6, ema_slow) < 6) {
      PrintFormat(">> [TREND DEBUG] Erro ao copiar EMA_Slow");
      return 0;
   }
   
   // EMA H1 para viés
   if(CopyBuffer(handleEMA_H1, 0, 0, 1, ema_h1) < 1) {
      PrintFormat(">> [TREND DEBUG] Erro ao copiar EMA_H1");
      return 0;
   }
   
   // ADX M5 para validar força do trend - coletar 20 períodos para média
   if(CopyBuffer(handleADX_M5, 0, 1, 20, adx_average) < 20) {
      PrintFormat(">> [TREND DEBUG] Erro ao copiar ADX para média");
      return 0;
   }
   
   // Calcular média de ADX dos últimos 20 períodos
   double adx_media_20 = 0;
   for(int i = 0; i < 20; i++) {
      adx_media_20 += adx_average[i];
   }
   adx_media_20 /= 20;
   
   // ADX atual
   double adx_now = adx_average[19];  // ✅ ADX mais recente (índice 19 = bar 20)
   
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
   
   // Calcular slope das EMAs (inclinação dos últimos 4 candles)
   // CopyBuffer com 6 períodos: índices 0-5, onde:
   // índice 5 = bar 6 (mais antigo), índice 0 = bar 1 (mais recente)
   // Para slope: ema_slow[0] - ema_slow[3] = bar1 - bar4 (últimos 3 candles)
   double slope_ema_fast = ema_fast[0] - ema_fast[3];   // Inclinação EMA9
   double slope_ema_slow = ema_slow[0] - ema_slow[3];   // Inclinação EMA21
   
   double atr_threshold = atr_avg * 0.1;  // Threshold = 10% do ATR médio
   
   double ema_fast_now = ema_fast[0];      // EMA9 atual
   double ema_slow_now = ema_slow[0];      // EMA21 atual
   
   PrintFormat(">> [TREND DEBUG] Close=%.5f EMA9=%.5f EMA21=%.5f | Slope9=%.5f Slope21=%.5f | ADX=%.2f(Média20=%.2f) | TrendWaiting=%s(Dir:%d)", 
               close_now, ema_fast_now, ema_slow_now, slope_ema_fast, slope_ema_slow, adx_now, adx_media_20, 
               trendSignalConfirmed ? "SIM" : "NÃO", trendSignalDirection);
   
   //=== ESTÁGIO 1: DETECTAR SINAL TREND (AGUARDANDO PULLBACK) ===
   if(!trendSignalConfirmed) {
      // SINAL DE COMPRA: EMA9 > EMA21 + Slopes positivos + ATR crescente + acima EMA H1 + ADX > média
      if(ema_fast[0] > ema_slow[0] && ema_fast[1] > ema_slow[1] && 
         slope_ema_fast > atr_threshold &&
         slope_ema_slow > atr_threshold &&
         atr_now > atr_avg * Trend_ATR_Growth &&
         close_now > ema_h1[0] &&
         adx_now > adx_media_20) {
         PrintFormat(">> [TREND SIGNAL DETECTED] COMPRA: Sinal confirmado!");
         PrintFormat("   Slope9(%.5f)>Threshold(%.5f) AND Slope21(%.5f)>Threshold AND ADX(%.2f)>Média20(%.2f)", 
                     slope_ema_fast, atr_threshold, slope_ema_slow, adx_now, adx_media_20);
         PrintFormat("   Aguardando PULLBACK até EMA9(%.5f) ou EMA21(%.5f)", ema_fast_now, ema_slow_now);
         
         trendSignalConfirmed = true;
         trendSignalDirection = +1;  // COMPRA
         trendSignalEMA9Level = ema_fast_now;
         trendSignalEMA21Level = ema_slow_now;
         trendPullbackAttempts = 0;
         return 0;  // Não entra ainda
      }
      
      // SINAL DE VENDA: EMA9 < EMA21 + Slopes negativos + ATR crescente + abaixo EMA H1 + ADX > média
      if(ema_fast[0] < ema_slow[0] && ema_fast[1] < ema_slow[1] && 
         slope_ema_fast < -atr_threshold &&
         slope_ema_slow < -atr_threshold &&
         atr_now > atr_avg * Trend_ATR_Growth &&
         close_now < ema_h1[0] &&
         adx_now > adx_media_20) {
         PrintFormat(">> [TREND SIGNAL DETECTED] VENDA: Sinal confirmado!");
         PrintFormat("   Slope9(%.5f)<-Threshold(%.5f) AND Slope21(%.5f)<-Threshold AND ADX(%.2f)>Média20(%.2f)", 
                     slope_ema_fast, atr_threshold, slope_ema_slow, adx_now, adx_media_20);
         PrintFormat("   Aguardando PULLBACK até EMA9(%.5f) ou EMA21(%.5f)", ema_fast_now, ema_slow_now);
         
         trendSignalConfirmed = true;
         trendSignalDirection = -1;  // VENDA
         trendSignalEMA9Level = ema_fast_now;
         trendSignalEMA21Level = ema_slow_now;
         trendPullbackAttempts = 0;
         return 0;  // Não entra ainda
      }
   }
   
   //=== ESTÁGIO 2: AGUARDAR E ENTRAR NO PULLBACK (MÁX 1 TENTATIVA) ===
   if(trendSignalConfirmed) {
      if(trendSignalDirection == +1) {
         // ESPERANDO PULLBACK PARA ENTRADA EM COMPRA (Close <= EMA9 ou EMA21)
         PrintFormat(">> [TREND PULLBACK WAIT] COMPRA: Close=%.5f | EMA9=%.5f EMA21=%.5f | Attempts=%d/1", 
                     close_now, trendSignalEMA9Level, trendSignalEMA21Level, trendPullbackAttempts);
         
         // Pullback até EMA9 ou EMA21
         if(close_now <= trendSignalEMA9Level || close_now <= trendSignalEMA21Level) {
            if(trendPullbackAttempts >= 1) {
               PrintFormat(">> [TREND BLOCKED] Já foi feita 1 tentativa de entrada. Aguardando próximo sinal...");
            } else {
               trendPullbackAttempts++;
               PrintFormat(">> [TREND PULLBACK ENTRY] COMPRA no pullback até EMA! (Tentativa %d/1)", trendPullbackAttempts);
               PrintFormat("   Close=%.5f <= EMA9(%.5f) ou EMA21(%.5f)", 
                           close_now, trendSignalEMA9Level, trendSignalEMA21Level);
               
               // Resetar para próximo sinal
               trendSignalConfirmed = false;
               trendSignalDirection = 0;
               trendSignalEMA9Level = 0;
               trendSignalEMA21Level = 0;
               trendPullbackAttempts = 0;
               
               return +1;  // SINAL DE COMPRA
            }
         }
         
         // Se Close subiu acima de ambas EMAs (sinal expirou), resetar
         if(close_now > trendSignalEMA9Level && close_now > trendSignalEMA21Level) {
            PrintFormat(">> [TREND SIGNAL EXPIRED] Pullback para cima expirou (Close acima de ambas EMAs). Resetando...");
            trendSignalConfirmed = false;
            trendSignalDirection = 0;
            trendSignalEMA9Level = 0;
            trendSignalEMA21Level = 0;
            trendPullbackAttempts = 0;
         }
      }
      else if(trendSignalDirection == -1) {
         // ESPERANDO PULLBACK PARA ENTRADA EM VENDA (Close >= EMA9 ou EMA21)
         PrintFormat(">> [TREND PULLBACK WAIT] VENDA: Close=%.5f | EMA9=%.5f EMA21=%.5f | Attempts=%d/1", 
                     close_now, trendSignalEMA9Level, trendSignalEMA21Level, trendPullbackAttempts);
         
         // Pullback até EMA9 ou EMA21
         if(close_now >= trendSignalEMA9Level || close_now >= trendSignalEMA21Level) {
            if(trendPullbackAttempts >= 1) {
               PrintFormat(">> [TREND BLOCKED] Já foi feita 1 tentativa de entrada. Aguardando próximo sinal...");
            } else {
               trendPullbackAttempts++;
               PrintFormat(">> [TREND PULLBACK ENTRY] VENDA no pullback até EMA! (Tentativa %d/1)", trendPullbackAttempts);
               PrintFormat("   Close=%.5f >= EMA9(%.5f) ou EMA21(%.5f)", 
                           close_now, trendSignalEMA9Level, trendSignalEMA21Level);
               
               // Resetar para próximo sinal
               trendSignalConfirmed = false;
               trendSignalDirection = 0;
               trendSignalEMA9Level = 0;
               trendSignalEMA21Level = 0;
               trendPullbackAttempts = 0;
               
               return -1;  // SINAL DE VENDA
            }
         }
         
         // Se Close caiu abaixo de ambas EMAs (sinal expirou), resetar
         if(close_now < trendSignalEMA9Level && close_now < trendSignalEMA21Level) {
            PrintFormat(">> [TREND SIGNAL EXPIRED] Pullback para baixo expirou (Close abaixo de ambas EMAs). Resetando...");
            trendSignalConfirmed = false;
            trendSignalDirection = 0;
            trendSignalEMA9Level = 0;
            trendSignalEMA21Level = 0;
            trendPullbackAttempts = 0;
         }
      }
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| MODELO 2: MEAN REVERSION (RANGE)                                 |
//+------------------------------------------------------------------+
int SignalMeanReversion() {
   if(!UseRangeModel || currentRegime != REGIME_RANGE) return 0;
   
   double bb_upper[], bb_lower[], bb_middle[];
   double stoch_k[], stoch_d[];
   double high[], low[], close[], open[];
   double atr[];
   
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
   
   // Dados de preço (copiar 2 candles para validar rejeição comparando com anterior)
   if(CopyHigh(_Symbol, PERIOD_M5, 0, 2, high) < 2) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar HIGH");
      return 0;
   }
   if(CopyLow(_Symbol, PERIOD_M5, 0, 2, low) < 2) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar LOW");
      return 0;
   }
   if(CopyClose(_Symbol, PERIOD_M5, 0, 2, close) < 2) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar CLOSE");
      return 0;
   }
   if(CopyOpen(_Symbol, PERIOD_M5, 0, 2, open) < 2) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar OPEN");
      return 0;
   }
   
   // ATR para validar lateralização (20 períodos para média)
   if(CopyBuffer(handleATR_M5, 0, 1, 20, atr) < 20) {
      PrintFormat(">> [RANGE DEBUG] Erro ao copiar ATR");
      return 0;
   }
   
   // ⚠️ CRÍTICO: Índices corretos para valores ATUAIS (mais recentes)
   // CopyHigh/Low/Close/Open(..., 0, 2, array) = array[0] = bar 1 (atual), array[1] = bar 2 (anterior)
   // Para comparar rejeição: array[0] = candle atual, array[1] = candle anterior
   
   double bb_upper_now = bb_upper[1];    // ✅ Banda superior atual
   double bb_lower_now = bb_lower[1];    // ✅ Banda inferior atual
   double bb_middle_now = bb_middle[1];  // ✅ Banda média atual
   
   // Dados do candle atual
   double high_now = high[0];            // ✅ High do candle atual
   double low_now = low[0];              // ✅ Low do candle atual
   double close_now = close[0];          // ✅ Close do candle atual
   double open_now = open[0];            // ✅ Open do candle atual
   
   // Dados do candle anterior
   double high_prev = high[1];           // ✅ High do candle anterior
   double low_prev = low[1];             // ✅ Low do candle anterior
   double close_prev = close[1];         // ✅ Close do candle anterior
   double open_prev = open[1];           // ✅ Open do candle anterior
   
   // ATR dinâmico - calcular média dos 20 últimos períodos
   double atr_now = atr[19];             // ✅ ATR mais recente (bar 20)
   double atr_avg = 0;
   for(int i = 0; i < 20; i++) {
      atr_avg += atr[i];
   }
   atr_avg /= 20;
   
   // Filtro de lateralização: ATR < 85% da média = mercado com baixa volatilidade
   bool allowRange = (atr_now < atr_avg * 0.85);
   
   // Filtro de pré-breakout: ATR > 110% da média = volatilidade aumentando, bloquear RANGE
   bool blockRange = (atr_now > atr_avg * 1.1);
   
   // Filtro de rejeição: validar candle de rejeição real (não apenas posição)
   // Rejeição BULLISH: High[0] > High[1] (novo máximo) && Close[0] < Open[0] (fecha abaixo da abertura)
   bool rejectionBullish = (high_now > high_prev && close_now < open_now);
   
   // Rejeição BEARISH: Low[0] < Low[1] (novo mínimo) && Close[0] > Open[0] (fecha acima da abertura)
   bool rejectionBearish = (low_now < low_prev && close_now > open_now);
   
   // Mean Reversion Strategy for WIN M5 RANGE:
   // Opera quando preço está afastado da média (mínimo 25% do band_range para zona de entrada expandida)
   double band_range = bb_upper_now - bb_lower_now;
   double distance_from_middle = close_now - bb_middle_now;
   double min_distance_threshold = band_range * 0.25;  // 25% do range (zona de entrada expandida)
   
   PrintFormat(">> [RANGE DEBUG] BBupper=%.5f BBmiddle=%.5f BBlower=%.5f | High=%.5f Low=%.5f Close=%.5f Open=%.5f", 
               bb_upper_now, bb_middle_now, bb_lower_now, high_now, low_now, close_now, open_now);
   PrintFormat(">> [RANGE DEBUG] ATR=%.0f ATRmedia=%.0f | Lateralização? %s (ATR < 85%%) | Pré-Breakout? %s (ATR > 110%%)",
               atr_now, atr_avg, allowRange ? "SIM" : "NÃO", blockRange ? "SIM" : "NÃO");
   PrintFormat(">> [RANGE DEBUG] Rejeição Bullish? %s (High[0]=%.5f > High[1]=%.5f && Close=%.5f < Open=%.5f)", 
               rejectionBullish ? "SIM" : "NÃO", high_now, high_prev, close_now, open_now);
   PrintFormat(">> [RANGE DEBUG] Rejeição Bearish? %s (Low[0]=%.5f < Low[1]=%.5f && Close=%.5f > Open=%.5f)", 
               rejectionBearish ? "SIM" : "NÃO", low_now, low_prev, close_now, open_now);
   PrintFormat(">> [RANGE DEBUG] Distância: %.0f | Threshold mín: %.0f | Close < Média-25%%? %s | Close > Média+25%%? %s",
               MathAbs(distance_from_middle), min_distance_threshold,
               (close_now < bb_middle_now - min_distance_threshold ? "SIM" : "NÃO"),
               (close_now > bb_middle_now + min_distance_threshold ? "SIM" : "NÃO"));
   
   // COMPRA: Close ABAIXO da média (mín 25%) + rejeição bullish + ATR lateralizado + NÃO em pré-breakout
   if(!blockRange && allowRange && close_now < bb_middle_now - min_distance_threshold && rejectionBullish) {
      PrintFormat(">> Sinal RANGE BUY: Close=%.5f < Média-25%%=%.5f (dist=%.0f) + rejeição bullish (High>High[1] && Close<Open) + ATR lateralizado", 
                  close_now, bb_middle_now - min_distance_threshold, MathAbs(distance_from_middle));
      return +1;
   }
   
   // VENDA: Close ACIMA da média (mín 25%) + rejeição bearish + ATR lateralizado + NÃO em pré-breakout
   if(!blockRange && allowRange && close_now > bb_middle_now + min_distance_threshold && rejectionBearish) {
      PrintFormat(">> Sinal RANGE SELL: Close=%.5f > Média+25%%=%.5f (dist=%.0f) + rejeição bearish (Low<Low[1] && Close>Open) + ATR lateralizado", 
                  close_now, bb_middle_now + min_distance_threshold, MathAbs(distance_from_middle));
      return -1;
   }
   
   PrintFormat(">> [RANGE DEBUG] Nenhum sinal gerado");
   
   return 0;
}

//+------------------------------------------------------------------+
//| MODELO 3: BREAKOUT COM PULLBACK                                 |
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
   double highPrev = high[1];  // High do candle anterior (índice 1)
   double lowPrev = low[1];    // Low do candle anterior (índice 1)
   
   for(int i = 2; i <= Breakout_ConsolidationBars; i++) {
      if(high[i] > maxHigh) maxHigh = high[i];
      if(low[i] < minLow) minLow = low[i];
   }
   
   double rangeSize = maxHigh - minLow;
   
   // ATR médio
   double avgATR = 0;
   for(int i = 0; i < Breakout_ConsolidationBars; i++) {
      if(atr[i] <= 0) {
         PrintFormat(">> ATR inválido em Breakout no índice %d: %.5f", i, atr[i]);
         return 0;
      }
      avgATR += atr[i];
   }
   avgATR /= Breakout_ConsolidationBars;
   
   // Índices corretos para candle ATUAL
   double currentClose = close[Breakout_ConsolidationBars];
   double currentATR = atr[Breakout_ConsolidationBars - 1];
   
   // Volume médio
   double avgVolume = 1.0;
   if(ArraySize(volume) > 0) {
      avgVolume = 0;
      for(int i = 1; i <= Breakout_ConsolidationBars; i++) {
         if(volume[i] > 0) avgVolume += volume[i];
      }
      avgVolume /= Breakout_ConsolidationBars;
      if(avgVolume <= 0) avgVolume = 1.0;
   }
   
   double currentVolume = ArraySize(volume) > 0 ? volume[Breakout_ConsolidationBars] : 1.0;
   
   PrintFormat(">> [BREAKOUT DEBUG] Close=%.5f | MaxHigh=%.5f | MinLow=%.5f | ATR=%.0f(Avg=%.0f) | Vol=%.0f(Avg=%.0f) | BreakoutWaiting=%s(Dir:%d)", 
               currentClose, maxHigh, minLow, currentATR, avgATR, currentVolume, avgVolume, breakoutConfirmed ? "SIM" : "NÃO", breakoutDirection);
   
   // Detectar confirmação de rompimento
   bool breakoutUp = currentClose > maxHigh + (currentATR * 0.1);
   bool breakoutDown = currentClose < minLow - (currentATR * 0.1);
   
   //=== ESTÁGIO 1: DETECTAR ROMPIMENTO COM SISTEMA DE SCORE ===
   if(!breakoutConfirmed && currentATR > avgATR) {
      // ROMPIMENTO PARA CIMA - Sistema de Score
      if(breakoutUp) {
         int scoreUp = 0;
         
         // Score 1: ATR expandindo
         if(currentATR > avgATR) scoreUp++;
         
         // Score 2: Volume acima da média
         if(currentVolume > avgVolume) scoreUp++;
         
         // Score 3: Close acima do High anterior
         if(currentClose > highPrev) scoreUp++;
         
         PrintFormat(">> [BREAKOUT SCORE UP] Close=%.5f > MaxHigh(%.5f) + ATR*0.1 | Score=%d/3 (ATR:%s | Vol:%s | ClosePrev:%s)",
                     currentClose, maxHigh, scoreUp,
                     (currentATR > avgATR ? "✓" : "✗"),
                     (currentVolume > avgVolume ? "✓" : "✗"),
                     (currentClose > highPrev ? "✓" : "✗"));
         
         if(scoreUp >= 2) {
            PrintFormat(">> [BREAKOUT CONFIRMATION] ROMPIMENTO UP detectado! Score=%d/3", scoreUp);
            PrintFormat("   Close=%.5f > MaxHigh(%.5f) + ATR(%.0f)*0.1", currentClose, maxHigh, currentATR);
            PrintFormat("   Aguardando PULLBACK até nível=%.5f ± ATR(%.0f)*0.2", maxHigh, currentATR);
            
            breakoutConfirmed = true;
            breakoutDirection = +1;
            breakoutLevel = maxHigh;
            breakoutATR = currentATR;
            breakoutPullbackAttempts = 0;  // Reset contador de tentativas
            return 0;
         }
      }
      
      // ROMPIMENTO PARA BAIXO - Sistema de Score
      if(breakoutDown) {
         int scoreDown = 0;
         
         // Score 1: ATR expandindo
         if(currentATR > avgATR) scoreDown++;
         
         // Score 2: Volume acima da média
         if(currentVolume > avgVolume) scoreDown++;
         
         // Score 3: Close abaixo do Low anterior
         if(currentClose < lowPrev) scoreDown++;
         
         PrintFormat(">> [BREAKOUT SCORE DOWN] Close=%.5f < MinLow(%.5f) - ATR*0.1 | Score=%d/3 (ATR:%s | Vol:%s | ClosePrev:%s)",
                     currentClose, minLow, scoreDown,
                     (currentATR > avgATR ? "✓" : "✗"),
                     (currentVolume > avgVolume ? "✓" : "✗"),
                     (currentClose < lowPrev ? "✓" : "✗"));
         
         if(scoreDown >= 2) {
            PrintFormat(">> [BREAKOUT CONFIRMATION] ROMPIMENTO DOWN detectado! Score=%d/3", scoreDown);
            PrintFormat("   Close=%.5f < MinLow(%.5f) - ATR(%.0f)*0.1", currentClose, minLow, currentATR);
            PrintFormat("   Aguardando PULLBACK até nível=%.5f ± ATR(%.0f)*0.2", minLow, currentATR);
            
            breakoutConfirmed = true;
            breakoutDirection = -1;
            breakoutLevel = minLow;
            breakoutATR = currentATR;
            breakoutPullbackAttempts = 0;  // Reset contador de tentativas
            return 0;
         }
      }
   }
   
   //=== ESTÁGIO 2: AGUARDAR E ENTRAR NO PULLBACK (MÁX 1 TENTATIVA) ===
   if(breakoutConfirmed) {
      double pullbackZoneMargin = breakoutATR * 0.2;  // Zona de entrada = nível ± 20% do ATR
      
      if(breakoutDirection == +1) {
         // ESPERANDO PULLBACK PARA ENTRADA EM COMPRA
         double upperPullbackZone = breakoutLevel + pullbackZoneMargin;
         double lowerPullbackZone = breakoutLevel - pullbackZoneMargin;
         
         PrintFormat(">> [BREAKOUT PULLBACK WAIT] UP: Close=%.5f | PullbackZone=[%.5f, %.5f] | Attempts=%d/1", 
                     currentClose, lowerPullbackZone, upperPullbackZone, breakoutPullbackAttempts);
         
         // Se Close volta para zona de pullback
         if(currentClose <= upperPullbackZone && currentClose >= lowerPullbackZone) {
            // Verificar se já teve 1 tentativa
            if(breakoutPullbackAttempts >= 1) {
               PrintFormat(">> [BREAKOUT BLOCKED] Já foi feita 1 tentativa de entrada. Aguardando próximo rompimento...");
            } else {
               breakoutPullbackAttempts++;  // Incrementar tentativa
               PrintFormat(">> [BREAKOUT PULLBACK ENTRY] COMPRA na zona de pullback! (Tentativa %d/1)", breakoutPullbackAttempts);
               PrintFormat("   Close=%.5f entrou na zona [%.5f, %.5f]", 
                           currentClose, lowerPullbackZone, upperPullbackZone);
               
               // Resetar para próximo breakout
               breakoutConfirmed = false;
               breakoutDirection = 0;
               breakoutLevel = 0;
               breakoutATR = 0;
               breakoutPullbackAttempts = 0;
               
               return +1;
            }
         }
         
         // Se Close voltou abaixo do nível (pullback terminou sem entrada), resetar
         if(currentClose < breakoutLevel - pullbackZoneMargin) {
            PrintFormat(">> [BREAKOUT PULLBACK EXPIRED] Pullback para cima expirou (Tentativas: %d/1). Resetando...", breakoutPullbackAttempts);
            breakoutConfirmed = false;
            breakoutDirection = 0;
            breakoutLevel = 0;
            breakoutATR = 0;
            breakoutPullbackAttempts = 0;
         }
      }
      else if(breakoutDirection == -1) {
         // ESPERANDO PULLBACK PARA ENTRADA EM VENDA
         double upperPullbackZone = breakoutLevel + pullbackZoneMargin;
         double lowerPullbackZone = breakoutLevel - pullbackZoneMargin;
         
         PrintFormat(">> [BREAKOUT PULLBACK WAIT] DOWN: Close=%.5f | PullbackZone=[%.5f, %.5f] | Attempts=%d/1", 
                     currentClose, lowerPullbackZone, upperPullbackZone, breakoutPullbackAttempts);
         
         // Se Close volta para zona de pullback
         if(currentClose >= lowerPullbackZone && currentClose <= upperPullbackZone) {
            // Verificar se já teve 1 tentativa
            if(breakoutPullbackAttempts >= 1) {
               PrintFormat(">> [BREAKOUT BLOCKED] Já foi feita 1 tentativa de entrada. Aguardando próximo rompimento...");
            } else {
               breakoutPullbackAttempts++;  // Incrementar tentativa
               PrintFormat(">> [BREAKOUT PULLBACK ENTRY] VENDA na zona de pullback! (Tentativa %d/1)", breakoutPullbackAttempts);
               PrintFormat("   Close=%.5f entrou na zona [%.5f, %.5f]", 
                           currentClose, lowerPullbackZone, upperPullbackZone);
               
               // Resetar para próximo breakout
               breakoutConfirmed = false;
               breakoutDirection = 0;
               breakoutLevel = 0;
               breakoutATR = 0;
               breakoutPullbackAttempts = 0;
               
               return -1;
            }
         }
         
         // Se Close voltou acima do nível (pullback terminou sem entrada), resetar
         if(currentClose > breakoutLevel + pullbackZoneMargin) {
            PrintFormat(">> [BREAKOUT PULLBACK EXPIRED] Pullback para baixo expirou (Tentativas: %d/1). Resetando...", breakoutPullbackAttempts);
            breakoutConfirmed = false;
            breakoutDirection = 0;
            breakoutLevel = 0;
            breakoutATR = 0;
            breakoutPullbackAttempts = 0;
         }
      }
   }
   
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
//| Verifica se está em período de cooldown após Stop Loss            |
//+------------------------------------------------------------------+
bool IsInCooldownPeriod(int tradeDirection) {
   if(lastStopLossTime == 0) {
      // Nenhum stop loss registrado ainda
      return false;
   }
   
   datetime now = TimeCurrent();
   int secondsElapsed = (int)(now - lastStopLossTime);
   int cooldownSeconds = CooldownMinutesAfterSL * 60;
   
   if(secondsElapsed < cooldownSeconds) {
      int minutesRemaining = (cooldownSeconds - secondsElapsed) / 60;
      int secondsRemaining = (cooldownSeconds - secondsElapsed) % 60;
      PrintFormat(">> [COOLDOWN] Aguardando: %d min %d seg (último SL em %s)", 
                  minutesRemaining, secondsRemaining, TimeToString(lastStopLossTime));
      return true;
   }
   
   // Cooldown expirou, resetar
   lastStopLossTime = 0;
   lastStopLossDirection = 0;
   return false;
}

//+------------------------------------------------------------------+
//| Verifica se pode abrir novo trade (OneTradePerBar)               |
//+------------------------------------------------------------------+
bool CanOpenTrade() {
   if(!UseOneTradePerBar) {
      return true;  // OneTradePerBar desativado
   }
   
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   
   if(lastTradeBarTime == currentBarTime) {
      PrintFormat(">> [ONE-TRADE-BAR] Já há trade aberto neste candle");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Verifica se a direção do trade é permitida (após SL)             |
//+------------------------------------------------------------------+
bool IsDirectionAllowed(int tradeDirection) {
   if(!UseDirectionCooldown || lastStopLossTime == 0) {
      return true;  // Nenhuma restrição de direção
   }
   
   datetime now = TimeCurrent();
   int secondsElapsed = (int)(now - lastStopLossTime);
   int cooldownSeconds = CooldownMinutesAfterSL * 60;
   
   // Se ainda está em cooldown e é a mesma direção
   if(secondsElapsed < cooldownSeconds && lastStopLossDirection == tradeDirection) {
      PrintFormat(">> [DIRECTION-BLOCK] Mesma direção (%s) bloqueada. Tempo restante: %d seg", 
                  tradeDirection > 0 ? "COMPRA" : "VENDA", 
                  cooldownSeconds - secondsElapsed);
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Verifica Motivos Válidos para Fechar Posição                     |
//+------------------------------------------------------------------+
bool ShouldClosePosition() {
   // A posição é fechada APENAS pelos seguintes motivos:
   // 1. Stop Loss foi acionado (SL hit)
   // 2. Take Profit foi acionado (TP hit)
   // NÃO fecha por mudança de regime de mercado
   
   if(!PositionSelect(_Symbol)) return false;
   
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long type = PositionGetInteger(POSITION_TYPE);
   
   if(type == POSITION_TYPE_BUY) {
      // Stop Loss Hit: bid <= SL
      if(sl > 0 && bid <= sl) {
         PrintFormat(">> [CLOSE] Stop Loss acionado (Buy): bid=%.5f <= sl=%.5f", bid, sl);
         return true;
      }
      // Take Profit Hit: bid >= TP
      if(tp > 0 && bid >= tp) {
         PrintFormat(">> [CLOSE] Take Profit acionado (Buy): bid=%.5f >= tp=%.5f", bid, tp);
         return true;
      }
   } else {
      // Stop Loss Hit: ask >= SL
      if(sl > 0 && ask >= sl) {
         PrintFormat(">> [CLOSE] Stop Loss acionado (Sell): ask=%.5f >= sl=%.5f", ask, sl);
         return true;
      }
      // Take Profit Hit: ask <= TP
      if(tp > 0 && ask <= tp) {
         PrintFormat(">> [CLOSE] Take Profit acionado (Sell): ask=%.5f <= tp=%.5f", ask, tp);
         return true;
      }
   }
   
   // Nenhum motivo válido para fechar
   return false;
}

//+------------------------------------------------------------------+
//| Gestão de Posição com Delay Mínimo                               |
//+------------------------------------------------------------------+
// IMPORTANTE: Esta função NÃO fecha a posição por mudança de regime!
// A posição é fechada APENAS quando:
//   - Stop Loss é acionado (SL hit)
//   - Take Profit é acionado (TP hit)
// O gerenciamento aqui é: Break-Even e Trailing Stop
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
   
   // Registrar regime na abertura da posição
   static ENUM_MARKET_REGIME positionOpenRegime = REGIME_UNDEFINED;
   if(positionOpenTime != posOpenTime) {
      positionOpenRegime = currentRegime;
      positionOpenTime = posOpenTime;
      barsAtPositionOpen = 0;
      PrintFormat(">> Posição aberta em: %s | Regime: %s | Troca de regime NÃO fechará", 
                  TimeToString(posOpenTime), currentRegimeStr);
      PrintFormat(">> Delay BE: %d candles | Delay Trailing: %d candles",
                  MinDelayBreakEvenBars, MinDelayTrailingBars);
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
   
   // Verificar se posição atingiu lucro mínimo de fechamento
   bool isBuy = (type == POSITION_TYPE_BUY);
   double currentPrice = isBuy ? bid : ask;
   
   if(!minClosureProfitReached) {
      if(HasReachedMinClosureProfit(isBuy, currentPrice, open)) {
         minClosureProfitReached = true;
         double minClosureProfit = CalculateMinClosureProfit();
         PrintFormat(">> [MIN CLOSURE REACHED] Posição atingiu lucro mínimo de fechamento: %.2f pontos", 
                     minClosureProfit / _Point);
      }
   }
   
   if(type == POSITION_TYPE_BUY) {
      currentProfit = bid - open;
      
      // Break-Even com delay mínimo E validação de lucro mínimo
      if(currentProfit >= tpDistance * BreakEvenTrigger && sl < open && 
         barsAtPositionOpen >= MinDelayBreakEvenBars && minClosureProfitReached) {
         double bePrice = open + (currentProfit * BreakEvenOffset);
         trade.PositionModify(_Symbol, NormalizePrice(bePrice), tp);
         PrintFormat(">> Break-Even ativado após %d candles (Buy)", barsAtPositionOpen);
      }
      
      // Trailing Stop com delay mínimo E validação de lucro mínimo
      if(currentProfit >= tpDistance * TrailingStart && 
         barsAtPositionOpen >= MinDelayTrailingBars && minClosureProfitReached) {
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
      
      // Break-Even com delay mínimo E validação de lucro mínimo
      if(currentProfit >= tpDistance * BreakEvenTrigger && (sl > open || sl == 0) && 
         barsAtPositionOpen >= MinDelayBreakEvenBars && minClosureProfitReached) {
         double bePrice = open - (currentProfit * BreakEvenOffset);
         trade.PositionModify(_Symbol, NormalizePrice(bePrice), tp);
         PrintFormat(">> Break-Even ativado após %d candles (Sell)", barsAtPositionOpen);
      }
      
      // Trailing Stop com delay mínimo E validação de lucro mínimo
      if(currentProfit >= tpDistance * TrailingStart && 
         barsAtPositionOpen >= MinDelayTrailingBars && minClosureProfitReached) {
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
   handleADX_M5 = iADX(_Symbol, PERIOD_M5, 14);  // ADX com período 14 no M5
   
   // Indicadores H1
   handleEMA_H1 = iMA(_Symbol, PERIOD_H1, Trend_EMA_H1, 0, MODE_EMA, PRICE_CLOSE);
   handleATR_H1 = iATR(_Symbol, PERIOD_H1, ATR_Period);
   
   if(handleATR_M5 == INVALID_HANDLE || handleEMA_Fast_M5 == INVALID_HANDLE || 
      handleEMA_Slow_M5 == INVALID_HANDLE || handleBB_M5 == INVALID_HANDLE ||
      handleStoch_M5 == INVALID_HANDLE || handleEMA_H1 == INVALID_HANDLE ||
      handleATR_H1 == INVALID_HANDLE || handleADX_M5 == INVALID_HANDLE) {
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
   
   // TREND: Resetar contador se mudou de regime
   if(currentRegime != REGIME_TREND) {
      trendTrades = 0;
   }
   
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
   
   // TREND: Bloquear novas entradas se já atingiu o limite de 2 trades consecutivos
   bool blockTrend = (trendTrades >= 2);
   
   switch(currentRegime) {
      case REGIME_TREND:
         if(blockTrend) {
            PrintFormat(">> [TREND BLOCKED] Atingido limite de 2 trades consecutivos (trendTrades=%d)", trendTrades);
            signal = 0;
         } else {
            signal = SignalTrendFollowing();
         }
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
   
   // Verificar Controle de Fluxo - Cooldown após Stop Loss
   if(IsInCooldownPeriod(signal)) {
      return;
   }
   
   // Verificar se a direção é permitida (bloqueio de mesma direção após SL)
   if(!IsDirectionAllowed(signal)) {
      return;
   }
   
   // Verificar OneTradePerBar
   if(!CanOpenTrade()) {
      return;
   }
   
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
         // Registrar timestamp do candle do trade para OneTradePerBar
         lastTradeBarTime = iTime(_Symbol, PERIOD_M5, 0);
         
         // Incrementar contador de trades TREND se regime é TREND
         if(currentRegime == REGIME_TREND) {
            trendTrades++;
            PrintFormat(">> [TREND TRADES] +1 COMPRA | Total: %d/2", trendTrades);
         }
         
         // Incrementar contador de trades TREND se regime é TREND
         if(currentRegime == REGIME_TREND) {
            trendTrades++;
            PrintFormat(">> [TREND TRADES] +1 COMPRA | Total: %d/2", trendTrades);
         }
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
         // Registrar timestamp do candle do trade para OneTradePerBar
         lastTradeBarTime = iTime(_Symbol, PERIOD_M5, 0);
         
         // Incrementar contador de trades TREND se regime é TREND
         if(currentRegime == REGIME_TREND) {
            trendTrades++;
            PrintFormat(">> [TREND TRADES] +1 VENDA | Total: %d/2", trendTrades);
         }
         
         // Incrementar contador de trades TREND se regime é TREND
         if(currentRegime == REGIME_TREND) {
            trendTrades++;
            PrintFormat(">> [TREND TRADES] +1 VENDA | Total: %d/2", trendTrades);
         }
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
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      
      // Detectar Stop Loss (prejuízo com tipo de entrada OUT)
      if((entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) && profit < 0) {
         // Registrar Stop Loss
         lastStopLossTime = TimeCurrent();
         
         // Determinar direção do trade que foi stopado
         // Procurar a entrada correspondente no histórico
         long dealTicket = trans.deal;
         long dealPosition = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
         
         // Procurar operação de entrada anterior
         for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
            ulong entry_deal = HistoryDealGetTicket(i);
            if(entry_deal == 0) continue;
            
            if(HistoryDealSelect(entry_deal)) {
               long entry_position = HistoryDealGetInteger(entry_deal, DEAL_POSITION_ID);
               long entry_type = HistoryDealGetInteger(entry_deal, DEAL_ENTRY);
               
               if(entry_position == dealPosition && (entry_type == DEAL_ENTRY_IN)) {
                  long dealDir = HistoryDealGetInteger(entry_deal, DEAL_TYPE);
                  lastStopLossDirection = (dealDir == DEAL_TYPE_BUY) ? 1 : -1;
                  break;
               }
            }
         }
         
         PrintFormat("=== STOP LOSS ACIONADO ===");
         PrintFormat("Prejuízo: %.2f", profit);
         PrintFormat("Direção: %s | Cooldown iniciado: %d minutos", 
                     lastStopLossDirection > 0 ? "COMPRA" : "VENDA", 
                     CooldownMinutesAfterSL);
         PrintFormat("=========================");
      }
      
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) {
         double volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
         
         string result = profit >= 0 ? "> GAIN" : "< LOSS";
         PrintFormat("==============================");
         PrintFormat("TRADE FECHADO: %.2f %s", profit, result);
         PrintFormat("Volume: %.2f | Preço: %.2f", 
                     volume, HistoryDealGetDouble(trans.deal, DEAL_PRICE));
         PrintFormat("==============================");
         
         // Resetar flag de lucro mínimo quando posição é fechada
         minClosureProfitReached = false;
         PrintFormat(">> [MIN CLOSURE] Flag resetada para próxima posição");
      }
   }
}