//+------------------------------------------------------------------+
//|                       MarketRegime.mq5                 |
//|              Adaptive System by MARKET REGIME                    |
//|                TREND • RANGE • BREAKOUT                          |
//+------------------------------------------------------------------+
#property copyright "hbgit, 2026."
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

// MARKET REGIME ENUMERATOR
enum ENUM_MARKET_REGIME {
   REGIME_UNDEFINED = 0,   // Undefined
   REGIME_TREND = 1,       // Trend
   REGIME_RANGE = 2,       // Range
   REGIME_BREAKOUT = 3     // Breakout
};

//============================================================================
// INPUTS - RISK MANAGEMENT
//============================================================================

input group "=== EA IDENTIFICATION ==="
input int MagicNumber = 2026001;       // EA unique Magic Number

input group "=== RISK MANAGEMENT ==="
input double RiskPercent = 1.0;        // Risk per trade (% capital)
input int DailyLossLimit = 250;        // Daily loss limit (points)

input group "=== REGIME DETECTOR (EA CORE) ==="
input int Regime_LookbackBars = 20;    // Candles for regime analysis
input double Regime_TrendThreshold = 0.75; // Directionality threshold (0-1)
input double Regime_RangeATRRatio = 0.7;   // Low ATR for range (× average)
input double Regime_BreakoutATRRatio = 1.3; // High ATR for breakout (× average)

input group "=== MODEL 1: TREND FOLLOWING ==="
input bool UseTrendModel = true;       // Enable Trend model
input int Trend_EMA_Fast = 9;          // Fast EMA M5
input int Trend_EMA_Slow = 21;         // Slow EMA M5
input int Trend_EMA_H1 = 50;           // EMA H1 for bias
input double Trend_ATR_Growth = 0.95;  // Growing ATR (× average) - REDUCED from 1.1 to 0.95
input double Trend_RiskReward = 2.0;   // R:R for trend
input double Trend_ADX_Threshold = 25.0; // Minimum ADX for trend (trend strength)

input group "=== MODEL 2: MEAN REVERSION (RANGE) ==="
input bool UseRangeModel = true;       // Enable Range model
input int Range_BB_Period = 20;        // Bollinger Bands period
input double Range_BB_Deviation = 2.0; // Standard deviations
input int Range_Stoch_K = 14;          // Stochastic %K
input int Range_Stoch_D = 3;           // Stochastic %D
input int Range_Stoch_Slowing = 3;     // Slowing
input double Range_RiskReward = 1.5;   // R:R for range

input group "=== MODEL 3: BREAKOUT ==="
input bool UseBreakoutModel = true;    // Enable Breakout model
input int Breakout_ConsolidationBars = 15; // Consolidation candles
input double Breakout_VolumeMultiplier = 1.8; // Volume above average
input double Breakout_RiskReward = 2.5; // R:R for breakout

input group "=== GENERAL FILTERS ==="
input int ATR_Period = 14;             // ATR Period
input int MaxSpread = 10;              // Maximum spread (points)
input double MaxSpreadPercentSL = 20.0; // Maximum spread in % of SL

input group "=== TRADING HOURS ==="
input int StartHour1 = 10;              // Morning Start
input int EndHour1 = 13;               // Morning End
input int StartHour2 = 14;             // Afternoon Start
input int EndHour2 = 17;               // Afternoon End

input group "=== DYNAMIC STOP LOSS ==="
input double ATR_StopMultiplier = 2.5; // ATR multiplier for SL
input int MinStopPoints = 100;         // Minimum stop (points)
input int MaxStopPoints = 300;         // Maximum stop (points)

input group "=== POSITION MANAGEMENT ==="
input double BreakEvenTrigger = 0.3;   // BE at % of TP (30%)
input double BreakEvenOffset = 0.5;    // BE offset (50% profit)
input double TrailingStart = 0.3;      // Trailing start (30% TP)
input double TrailingStep = 0.3;       // Trailing step (30% movement)
input int MinDelayBreakEvenBars = 5;   // Minimum delay for BE (candles)
input int MinDelayTrailingBars = 8;    // Minimum delay for trailing (candles)
input bool UseParcialExit = true;      // Partial exit (50% at TP1)

input group "=== FLOW CONTROL ==="
input bool UseOneTradePerBar = true;   // One trade per candle
input int CooldownMinutesAfterSL = 15; // Cooldown time after Stop Loss (minutes)
input bool UseDirectionCooldown = true; // Prevent same direction after SL

//============================================================================
// GLOBAL VARIABLES
//============================================================================

// Indicator Handles
int handleATR_M5, handleATR_H1;
int handleEMA_Fast_M5, handleEMA_Slow_M5, handleEMA_H1;
int handleBB_M5, handleStoch_M5;
int handleADX_M5;  // Handle for ADX on M5 timeframe
int handleRSI_M5;  // Handle for RSI on M5 timeframe

// Controls
double lotSize;
bool tradingBlocked = false;
int lastDay = -1;
static datetime lastBarTime = 0;
double dailyLossInPoints = 0.0;

// Position Tracking
static datetime positionOpenTime = 0;
static int barsAtPositionOpen = 0;
static ENUM_MARKET_REGIME currentRegime = REGIME_UNDEFINED;
static string currentRegimeStr = "UNDEFINED";

// Flow Control - OneTradePerBar
static datetime lastTradeBarTime = 0;  // Timestamp of last trade candle

// Flow Control - Cooldown after Stop Loss
static datetime lastStopLossTime = 0;  // Time of last stop loss
static int lastStopLossDirection = 0;  // Direction of last stop loss (+1 buy, -1 sell, 0 none)

// Flow Control - BREAKOUT with Pullback
static bool breakoutConfirmed = false;      // Flag: breakout detected, waiting for pullback
static int breakoutDirection = 0;           // Breakout direction (+1 = up, -1 = down, 0 = none)
static double breakoutLevel = 0;            // Breakout level (MaxHigh or MinLow)
static double breakoutATR = 0;              // ATR at breakout moment (for pullback calculation)
static int breakoutPullbackAttempts = 0;    // Counter for pullback entry attempts (max 1)
static ulong breakoutLimitOrderTicket = 0;  // Pending breakout limit order ticket

// Flow Control - TREND with Pullback
static bool trendSignalConfirmed = false;   // Flag: TREND signal detected, waiting for pullback to EMA
static int trendSignalDirection = 0;        // Signal direction (+1 buy, -1 sell, 0 = none)
static double trendSignalEMA9Level = 0;     // EMA9 level at signal moment
static double trendSignalEMA21Level = 0;    // EMA21 level at signal moment

// Minimum Closure Control
static bool minClosureProfitReached = false; // Flag: minimum closure profit reached

// Regime Confirmation Control
static int regimeConfirmationCount = 3;     // Regime confirmation counter (3 = confirmed)
static int trendPullbackAttempts = 0;       // Entry attempt counter (max 1)

// Consecutive Trades Control - TREND
static int trendTrades = 0;                 // Counter for consecutive TREND trades (max 2)

// Indicator Warmup
static int barsLoaded = 0;
const int WARMUP_BARS = 50;  // Minimum number of bars for warmup

//============================================================================
// MATHEMATICAL AND UTILITY FUNCTIONS
//============================================================================

double NormalizePrice(double price) {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

bool ValidateStops(bool isBuy, double entryPrice, double slPrice, double tpPrice) {
   // Get minimum stop level from broker
   int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopLevel * _Point;
   
   if(stopLevel > 0) {
      if(isBuy) {
         // For buy: SL must be below and TP above
         if((entryPrice - slPrice) < minDistance) {
            PrintFormat(">> ERROR: SL too close. Dist=%.5f Min=%.5f", (entryPrice - slPrice), minDistance);
            return false;
         }
         if((tpPrice - entryPrice) < minDistance) {
            PrintFormat(">> ERROR: TP too close. Dist=%.5f Min=%.5f", (tpPrice - entryPrice), minDistance);
            return false;
         }
      } else {
         // For sell: SL must be above and TP below
         if((slPrice - entryPrice) < minDistance) {
            PrintFormat(">> ERROR: SL too close. Dist=%.5f Min=%.5f", (slPrice - entryPrice), minDistance);
            return false;
         }
         if((entryPrice - tpPrice) < minDistance) {
            PrintFormat(">> ERROR: TP too close. Dist=%.5f Min=%.5f", (entryPrice - tpPrice), minDistance);
            return false;
         }
      }
   }
   
   // Validate that SL and TP are not zero and make sense
   if(slPrice <= 0 || tpPrice <= 0) {
      PrintFormat(">> ERROR: Invalid SL or TP. SL=%.5f TP=%.5f", slPrice, tpPrice);
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Calculate Minimum Closure Profit                                 |
//+------------------------------------------------------------------+
double CalculateMinClosureProfit() {
   double atr[];
   if(CopyBuffer(handleATR_M5, 0, 1, 1, atr) < 1) {
      return 20 * _Point;  // Fallback if copying ATR fails
   }
   
   double atrValue = atr[0];
   double operationalMinimum = 20 * _Point;
   double volatilityAdaptation = atrValue * 0.25;
   
   return MathMax(operationalMinimum, volatilityAdaptation);
}

//+------------------------------------------------------------------+
//| Validate if Position Reached Minimum Closure Profit              |
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
   
   PrintFormat(">> [MIN CLOSURE] Current Profit: %.2f pts | Minimum Required: %.2f pts", 
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
//| CORE: MARKET REGIME DETECTOR (RAW - NO HYSTERESIS)              |
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME DetectMarketRegimeRaw() {
   double atr_m5[];
   double high[], low[], close[];
   
   // Validation: Minimum number of bars loaded
   int bars = iBars(_Symbol, PERIOD_M5);
   if(bars < Regime_LookbackBars + 10) {
      PrintFormat(">> Insufficient data. Bars available: %d / Required: %d", 
                  bars, Regime_LookbackBars + 10);
      return REGIME_UNDEFINED;
   }
   
   // Get ATR for volatility
   if(CopyBuffer(handleATR_M5, 0, 1, Regime_LookbackBars, atr_m5) < Regime_LookbackBars) {
      PrintFormat(">> Error copying ATR. Returned: %d / Expected: %d", 
                  CopyBuffer(handleATR_M5, 0, 1, Regime_LookbackBars, atr_m5), 
                  Regime_LookbackBars);
      return REGIME_UNDEFINED;
   }
   
   // Calculate average ATR
   double atr_avg = 0;
   for(int i = 0; i < Regime_LookbackBars; i++) {
      if(atr_m5[i] <= 0) {
         PrintFormat(">> Invalid ATR at index %d: %.5f", i, atr_m5[i]);
         return REGIME_UNDEFINED;
      }
      atr_avg += atr_m5[i];
   }
   atr_avg /= Regime_LookbackBars;
   
   double atr_current = atr_m5[Regime_LookbackBars-1];
   
   // Get price data
   if(CopyHigh(_Symbol, PERIOD_M5, 1, Regime_LookbackBars, high) < Regime_LookbackBars) {
      PrintFormat(">> Error copying HIGH");
      return REGIME_UNDEFINED;
   }
   if(CopyLow(_Symbol, PERIOD_M5, 1, Regime_LookbackBars, low) < Regime_LookbackBars) {
      PrintFormat(">> Error copying LOW");
      return REGIME_UNDEFINED;
   }
   if(CopyClose(_Symbol, PERIOD_M5, 1, Regime_LookbackBars, close) < Regime_LookbackBars) {
      PrintFormat(">> Error copying CLOSE");
      return REGIME_UNDEFINED;
   }
   
   // 1. DETECT BREAKOUT: Expanding ATR + broken range
   double maxHigh = high[ArrayMaximum(high)];
   double minLow = low[ArrayMinimum(low)];
   double rangeSize = maxHigh - minLow;
   double currentClose = close[Regime_LookbackBars-1];
   
   if(rangeSize <= 0) {
      PrintFormat(">> Invalid range: %.5f", rangeSize);
      return REGIME_UNDEFINED;
   }
   
   if(atr_current > atr_avg * Regime_BreakoutATRRatio) {
      // High ATR - check for breakout
      if(currentClose > maxHigh - rangeSize * 0.2 || currentClose < minLow + rangeSize * 0.2) {
         PrintFormat(">> REGIME RAW: BREAKOUT (ATR=%.0f > Average=%.0f * %.2f)", 
                     atr_current, atr_avg, Regime_BreakoutATRRatio);
         return REGIME_BREAKOUT;
      }
   }
   
   // 2. DETECT RANGE: Low ATR + oscillating price + ADX < 20
   if(atr_current < atr_avg * Regime_RangeATRRatio) {
      // Check oscillation: price should not be in clear trend
      int upmoves = 0, downmoves = 0;
      for(int i = 1; i < Regime_LookbackBars; i++) {
         if(close[i] > close[i-1]) upmoves++;
         else if(close[i] < close[i-1]) downmoves++;
      }
      
      double directionality = MathAbs(upmoves - downmoves) / (double)Regime_LookbackBars;
      
      // Add ADX < 20 validation (indicates lack of trend)
      double adx[];
      if(CopyBuffer(handleADX_M5, 0, 1, 1, adx) >= 1) {
         double adx_now = adx[0];
         
         if(directionality < Regime_TrendThreshold && adx_now < 20.0) {
            PrintFormat(">> REGIME RAW: RANGE (ATR=%.0f < Average=%.0f * %.2f, Directionality=%.2f, ADX=%.2f < 20)", 
                        atr_current, atr_avg, Regime_RangeATRRatio, directionality, adx_now);
            return REGIME_RANGE;
         }
      }
   }
   
   // 3. DETECT TREND: Clear directionality
   double ema_fast[], ema_slow[];
   if(CopyBuffer(handleEMA_Fast_M5, 0, 1, 10, ema_fast) < 10) {
      PrintFormat(">> Error copying EMA Fast");
      return REGIME_UNDEFINED;
   }
   if(CopyBuffer(handleEMA_Slow_M5, 0, 1, 10, ema_slow) < 10) {
      PrintFormat(">> Error copying EMA Slow");
      return REGIME_UNDEFINED;
   }
   
   // EMAs consistently aligned
   bool trendUp = true, trendDown = true;
   for(int i = 0; i < 10; i++) {
      if(ema_fast[i] <= ema_slow[i]) trendUp = false;
      if(ema_fast[i] >= ema_slow[i]) trendDown = false;
   }
   
   if(trendUp || trendDown) {
      // Confirm with growing ATR
      if(atr_current >= atr_avg * Trend_ATR_Growth) {
         PrintFormat(">> REGIME RAW: TREND (ATR=%.0f >= Average=%.0f * %.2f, %s)", 
                     atr_current, atr_avg, Trend_ATR_Growth, trendUp ? "UP" : "DOWN");
         return REGIME_TREND;
      }
   }
   
   return REGIME_UNDEFINED;
}

//+------------------------------------------------------------------+
//| CORE: REGIME DETECTOR WITH CONFIRMATION (HYSTERESIS)            |
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME DetectMarketRegime() {
   ENUM_MARKET_REGIME newRegime = DetectMarketRegimeRaw(); // Detect regime without hysteresis
   
   // If detected regime is the same as current, confirm immediately
   if(newRegime == currentRegime) {
      regimeConfirmationCount = 3;  // Reset confirmation counter
      return currentRegime;
   }
   
   // If regime changed, require confirmation in 2-3 consecutive candles
   regimeConfirmationCount--;
   
   PrintFormat(">> [REGIME CONFIRMATION] New regime detected: %s | Current: %s | Confirmations remaining: %d", 
               GetRegimeString(newRegime), currentRegimeStr, regimeConfirmationCount);
   
   // When counter reaches zero or negative, accept the change
   if(regimeConfirmationCount <= 0) {
      ENUM_MARKET_REGIME previousRegime = currentRegime;
      currentRegime = newRegime;
      regimeConfirmationCount = 3;  // Reset counter for future changes
      
      // Update regime string
      switch(currentRegime) {
         case REGIME_TREND:
            currentRegimeStr = "TREND";
            break;
         case REGIME_RANGE:
            currentRegimeStr = "RANGE";
            break;
         case REGIME_BREAKOUT:
            currentRegimeStr = "BREAKOUT";
            break;
         default:
            currentRegimeStr = "UNDEFINED";
            break;
      }
      
      PrintFormat("========================================");
      PrintFormat(">> [REGIME CHANGED] %s → %s (confirmed after 2-3 candles)", 
                  GetRegimeString(previousRegime), currentRegimeStr);
      PrintFormat("========================================");
   }
   
   return currentRegime;
}

//+------------------------------------------------------------------+
//| Returns Regime String                                            |
//+------------------------------------------------------------------+
string GetRegimeString(ENUM_MARKET_REGIME regime) {
   switch(regime) {
      case REGIME_TREND: return "TREND";
      case REGIME_RANGE: return "RANGE";
      case REGIME_BREAKOUT: return "BREAKOUT";
      default: return "UNDEFINED";
   }
}

//+------------------------------------------------------------------+
//| MODELO 1: TREND FOLLOWING                                        |
//+------------------------------------------------------------------+
int SignalTrendFollowing() {
   if(!UseTrendModel || currentRegime != REGIME_TREND) return 0;
   
   double ema_fast[], ema_slow[], ema_h1[];
   double atr_current[], atr_prev[];
   double adx[], adx_average[];
   
   // EMAs M5 - collect 6 periods to calculate slope (EMA[0] - EMA[3])
   if(CopyBuffer(handleEMA_Fast_M5, 0, 1, 6, ema_fast) < 6) {
      PrintFormat(">> [TREND DEBUG] Error copying EMA_Fast");
      return 0;
   }
   if(CopyBuffer(handleEMA_Slow_M5, 0, 1, 6, ema_slow) < 6) {
      PrintFormat(">> [TREND DEBUG] Error copying EMA_Slow");
      return 0;
   }
   
   // EMA H1 for bias - collect 4 periods to calculate slope
   if(CopyBuffer(handleEMA_H1, 0, 0, 4, ema_h1) < 4) {
      PrintFormat(">> [TREND DEBUG] Error copying EMA_H1");
      return 0;
   }
   
   // Calculate EMA H1 slope (inclination of last 3 H1 candles)
   // ema_h1[0] = current bar, ema_h1[3] = 3 bars ago
   double slope_ema_h1 = ema_h1[0] - ema_h1[3];
   
   // ADX M5 to validate trend strength - collect 20 periods for average
   if(CopyBuffer(handleADX_M5, 0, 1, 20, adx_average) < 20) {
      PrintFormat(">> [TREND DEBUG] Error copying ADX for average");
      return 0;
   }
   
   // Calculate ADX average of last 20 periods
   double adx_media_20 = 0;
   for(int i = 0; i < 20; i++) {
      adx_media_20 += adx_average[i];
   }
   adx_media_20 /= 20;
   
   // Current ADX
   double adx_now = adx_average[19];  // ✅ Most recent ADX (index 19 = bar 20)
   
   // Growing ATR - use 20 bars as in DetectMarketRegime() for consistency
   if(CopyBuffer(handleATR_M5, 0, 1, 20, atr_current) < 20) {
      PrintFormat(">> [TREND DEBUG] Error copying ATR");
      return 0;
   }
   
   // ⚠️ CRITICAL: Correct indices for CURRENT (most recent) values
   // Averaged over 20 bars like DetectMarketRegime() for consistency
   // atr_current[0] = bar 1 (old), atr_current[19] = bar 20 (current/recent)
   double atr_now = atr_current[19];      // ✅ Most recent ATR (bar 20)
   double atr_avg = 0;
   for(int i = 0; i < 20; i++) atr_avg += atr_current[i];  // ✅ Average of last 20
   atr_avg /= 20;
   
   double close_now = iClose(_Symbol, PERIOD_M5, 1);
   
   // Calculate EMA slopes (inclination of last 4 candles)
   // CopyBuffer with 6 periods: indices 0-5, where:
   // index 5 = bar 6 (oldest), index 0 = bar 1 (most recent)
   // For slope: ema_slow[0] - ema_slow[3] = bar1 - bar4 (last 3 candles)
   double slope_ema_fast = ema_fast[0] - ema_fast[3];   // EMA9 inclination
   double slope_ema_slow = ema_slow[0] - ema_slow[3];   // EMA21 inclination
   
   double atr_threshold = atr_avg * 0.1;  // Threshold = 10% of average ATR
   
   double ema_fast_now = ema_fast[0];      // Current EMA9
   double ema_slow_now = ema_slow[0];      // Current EMA21
   
   PrintFormat(">> [TREND DEBUG] Close=%.5f EMA9=%.5f EMA21=%.5f EMAH1=%.5f | Slope9=%.5f Slope21=%.5f SlopeH1=%.5f | ADX=%.2f(Average20=%.2f) | TrendWaiting=%s(Dir:%d)", 
               close_now, ema_fast_now, ema_slow_now, ema_h1[0], slope_ema_fast, slope_ema_slow, slope_ema_h1, adx_now, adx_media_20, 
               trendSignalConfirmed ? "YES" : "NO", trendSignalDirection);

   bool ema_cross_buy = (ema_fast[0] > ema_slow[0] && ema_fast[1] > ema_slow[1]);
   bool ema_cross_sell = (ema_fast[0] < ema_slow[0] && ema_fast[1] < ema_slow[1]);
   bool ema_cross_condition = ema_cross_buy || ema_cross_sell;

   bool adx_condition = (adx_now > adx_media_20);
   bool atr_growth_condition = (atr_now > atr_avg * Trend_ATR_Growth);

   bool h1_bias_buy = (close_now > ema_h1[0] && slope_ema_h1 > 0);
   bool h1_bias_sell = (close_now < ema_h1[0] && slope_ema_h1 < 0);
   bool h1_bias_condition = h1_bias_buy || h1_bias_sell;
   
   bool slope_buy_condition = (slope_ema_fast > atr_threshold && slope_ema_slow > atr_threshold);
   bool slope_sell_condition = (slope_ema_fast < -atr_threshold && slope_ema_slow < -atr_threshold);
   
   //=== STAGE 1: DETECT TREND SIGNAL (DIRECT ENTRY OR WAITING FOR PULLBACK) ===
   if(!trendSignalConfirmed) {
      bool buy_setup = ema_cross_buy && slope_buy_condition && atr_growth_condition && h1_bias_buy && adx_condition;
      bool sell_setup = ema_cross_sell && slope_sell_condition && atr_growth_condition && h1_bias_sell && adx_condition;

      // BUY SIGNAL: EMA9 > EMA21 + Positive slopes + Growing ATR + above EMA H1 + EMA H1 sloped upward + ADX > average
      if(buy_setup) {
         
         // DIRECT ENTRY: ADX > 30 and strong slope (> 1.5x threshold)
         bool strongTrend = (adx_now > 30.0) && (slope_ema_fast > atr_threshold * 1.5) && (slope_ema_slow > atr_threshold * 1.5);
         
         if(strongTrend) {
            PrintFormat(">> [TREND DIRECT ENTRY] BUY: Strong trend detected! ADX=%.2f > 30 and strong slopes", adx_now);
            PrintFormat("   Slope9(%.5f)>1.5xThreshold(%.5f) AND Slope21(%.5f)>1.5xThreshold", 
                        slope_ema_fast, atr_threshold * 1.5, slope_ema_slow);
            PrintFormat("   ENTERING IMMEDIATELY without pullback!");
            return +1;  // IMMEDIATE BUY
         } else {
            PrintFormat(">> [TREND SIGNAL DETECTED] BUY: Signal confirmed!");
            PrintFormat("   Slope9(%.5f)>Threshold(%.5f) AND Slope21(%.5f)>Threshold AND SlopeH1(%.5f)>0 AND ADX(%.2f)>Average20(%.2f)", 
                        slope_ema_fast, atr_threshold, slope_ema_slow, slope_ema_h1, adx_now, adx_media_20);
            PrintFormat("   Waiting for PULLBACK to EMA9(%.5f) or EMA21(%.5f)", ema_fast_now, ema_slow_now);
            
            trendSignalConfirmed = true;
            trendSignalDirection = +1;  // BUY
            trendSignalEMA9Level = ema_fast_now;
            trendSignalEMA21Level = ema_slow_now;
            trendPullbackAttempts = 0;
            return 0;  // Don't enter yet, wait for pullback
         }
      }
      
      // SELL SIGNAL: EMA9 < EMA21 + Negative slopes + Growing ATR + below EMA H1 + EMA H1 sloped downward + ADX > average
      else if(sell_setup) {
         
         // DIRECT ENTRY: ADX > 30 and strong slope (< -1.5x threshold)
         bool strongTrend = (adx_now > 30.0) && (slope_ema_fast < -atr_threshold * 1.5) && (slope_ema_slow < -atr_threshold * 1.5);
         
         if(strongTrend) {
            PrintFormat(">> [TREND DIRECT ENTRY] SELL: Strong trend detected! ADX=%.2f > 30 and strong slopes", adx_now);
            PrintFormat("   Slope9(%.5f)<-1.5xThreshold(%.5f) AND Slope21(%.5f)<-1.5xThreshold", 
                        slope_ema_fast, -atr_threshold * 1.5, slope_ema_slow);
            PrintFormat("   ENTERING IMMEDIATELY without pullback!");
            return -1;  // IMMEDIATE SELL
         } else {
            PrintFormat(">> [TREND SIGNAL DETECTED] SELL: Signal confirmed!");
            PrintFormat("   Slope9(%.5f)<-Threshold(%.5f) AND Slope21(%.5f)<-Threshold AND SlopeH1(%.5f)<0 AND ADX(%.2f)>Average20(%.2f)", 
                        slope_ema_fast, atr_threshold, slope_ema_slow, slope_ema_h1, adx_now, adx_media_20);
            PrintFormat("   Waiting for PULLBACK to EMA9(%.5f) or EMA21(%.5f)", ema_fast_now, ema_slow_now);
            
            trendSignalConfirmed = true;
            trendSignalDirection = -1;  // SELL
            trendSignalEMA9Level = ema_fast_now;
            trendSignalEMA21Level = ema_slow_now;
            trendPullbackAttempts = 0;
            return 0;  // Don't enter yet, wait for pullback
         }
      }
      else {
         if(!ema_cross_condition) {
            PrintFormat(">> [BLOCK] EMA cross falhou (EMA9=%.5f | EMA21=%.5f | EMA9[1]=%.5f | EMA21[1]=%.5f)", 
                        ema_fast[0], ema_slow[0], ema_fast[1], ema_slow[1]);
         }
         if(!adx_condition) {
            PrintFormat(">> [BLOCK] ADX baixo (ADX=%.2f <= Media20=%.2f)", adx_now, adx_media_20);
         }
         if(!atr_growth_condition) {
            PrintFormat(">> [BLOCK] ATR não cresceu suficiente (ATR=%.0f <= Avg*Grow=%.0f)", atr_now, atr_avg * Trend_ATR_Growth);
         }
         if(!h1_bias_condition) {
            PrintFormat(">> [BLOCK] Viés H1 não alinhado (Close=%.5f | EMAH1=%.5f | SlopeH1=%.5f)", close_now, ema_h1[0], slope_ema_h1);
         }
      }
   }
   
   //=== STAGE 2: WAIT AND ENTER ON PULLBACK (MAX 1 ATTEMPT) ===
   if(trendSignalConfirmed) {
      if(trendSignalDirection == +1) {
         // WAITING FOR PULLBACK TO BUY ENTRY (Close <= EMA9 or EMA21)
         PrintFormat(">> [TREND PULLBACK WAIT] BUY: Close=%.5f | EMA9=%.5f EMA21=%.5f | Attempts=%d/1", 
                     close_now, trendSignalEMA9Level, trendSignalEMA21Level, trendPullbackAttempts);
         
         // Pullback to EMA9 or EMA21
         bool pullback_condition = (close_now <= trendSignalEMA9Level || close_now <= trendSignalEMA21Level);
         if(pullback_condition) {
            if(trendPullbackAttempts >= 1) {
               PrintFormat(">> [TREND BLOCKED] Already made 1 entry attempt. Waiting for next signal...");
            } else {
               trendPullbackAttempts++;
               PrintFormat(">> [TREND PULLBACK ENTRY] BUY on pullback to EMA! (Attempt %d/1)", trendPullbackAttempts);
               PrintFormat("   Close=%.5f <= EMA9(%.5f) or EMA21(%.5f)", 
                           close_now, trendSignalEMA9Level, trendSignalEMA21Level);
               
               // Reset for next signal
               trendSignalConfirmed = false;
               trendSignalDirection = 0;
               trendSignalEMA9Level = 0;
               trendSignalEMA21Level = 0;
               trendPullbackAttempts = 0;
               
               return +1;  // BUY SIGNAL
            }
         }
         else {
            PrintFormat(">> [BLOCK] Pullback não ocorreu (Close=%.5f | EMA9=%.5f | EMA21=%.5f)", 
                        close_now, trendSignalEMA9Level, trendSignalEMA21Level);
         }
         
         // If Close rose above both EMAs (signal expired), reset
         if(close_now > trendSignalEMA9Level && close_now > trendSignalEMA21Level) {
            PrintFormat(">> [TREND SIGNAL EXPIRED] Upward pullback expired (Close above both EMAs). Resetting...");
            trendSignalConfirmed = false;
            trendSignalDirection = 0;
            trendSignalEMA9Level = 0;
            trendSignalEMA21Level = 0;
            trendPullbackAttempts = 0;
         }
      }
      else if(trendSignalDirection == -1) {
         // WAITING FOR PULLBACK TO SELL ENTRY (Close >= EMA9 or EMA21)
         PrintFormat(">> [TREND PULLBACK WAIT] SELL: Close=%.5f | EMA9=%.5f EMA21=%.5f | Attempts=%d/1", 
                     close_now, trendSignalEMA9Level, trendSignalEMA21Level, trendPullbackAttempts);
         
         // Pullback to EMA9 or EMA21
         bool pullback_condition = (close_now >= trendSignalEMA9Level || close_now >= trendSignalEMA21Level);
         if(pullback_condition) {
            if(trendPullbackAttempts >= 1) {
               PrintFormat(">> [TREND BLOCKED] Already made 1 entry attempt. Waiting for next signal...");
            } else {
               trendPullbackAttempts++;
               PrintFormat(">> [TREND PULLBACK ENTRY] SELL on pullback to EMA! (Attempt %d/1)", trendPullbackAttempts);
               PrintFormat("   Close=%.5f >= EMA9(%.5f) or EMA21(%.5f)", 
                           close_now, trendSignalEMA9Level, trendSignalEMA21Level);
               
               // Reset for next signal
               trendSignalConfirmed = false;
               trendSignalDirection = 0;
               trendSignalEMA9Level = 0;
               trendSignalEMA21Level = 0;
               trendPullbackAttempts = 0;
               
               return -1;  // SELL SIGNAL
            }
         }
         else {
            PrintFormat(">> [BLOCK] Pullback não ocorreu (Close=%.5f | EMA9=%.5f | EMA21=%.5f)", 
                        close_now, trendSignalEMA9Level, trendSignalEMA21Level);
         }
         
         // If Close fell below both EMAs (signal expired), reset
         if(close_now < trendSignalEMA9Level && close_now < trendSignalEMA21Level) {
            PrintFormat(">> [TREND SIGNAL EXPIRED] Downward pullback expired (Close below both EMAs). Resetting...");
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
   double rsi[];
   
   // Bollinger Bands
   if(CopyBuffer(handleBB_M5, 1, 1, 2, bb_upper) < 2) {
      PrintFormat(">> [RANGE DEBUG] Error copying BB Upper");
      return 0;
   }
   if(CopyBuffer(handleBB_M5, 2, 1, 2, bb_lower) < 2) {
      PrintFormat(">> [RANGE DEBUG] Error copying BB Lower");
      return 0;
   }
   if(CopyBuffer(handleBB_M5, 0, 1, 2, bb_middle) < 2) {
      PrintFormat(">> [RANGE DEBUG] Error copying BB Middle");
      return 0;
   }
   
   // Stochastic
   if(CopyBuffer(handleStoch_M5, 0, 1, 3, stoch_k) < 3) {
      PrintFormat(">> [RANGE DEBUG] Error copying Stoch K");
      return 0;
   }
   if(CopyBuffer(handleStoch_M5, 1, 1, 3, stoch_d) < 3) {
      PrintFormat(">> [RANGE DEBUG] Error copying Stoch D");
      return 0;
   }
   
   // Price data (copy 2 candles to validate rejection comparing with previous)
   if(CopyHigh(_Symbol, PERIOD_M5, 0, 2, high) < 2) {
      PrintFormat(">> [RANGE DEBUG] Error copying HIGH");
      return 0;
   }
   if(CopyLow(_Symbol, PERIOD_M5, 0, 2, low) < 2) {
      PrintFormat(">> [RANGE DEBUG] Error copying LOW");
      return 0;
   }
   if(CopyClose(_Symbol, PERIOD_M5, 0, 2, close) < 2) {
      PrintFormat(">> [RANGE DEBUG] Error copying CLOSE");
      return 0;
   }
   if(CopyOpen(_Symbol, PERIOD_M5, 0, 2, open) < 2) {
      PrintFormat(">> [RANGE DEBUG] Error copying OPEN");
      return 0;
   }
   
   // ATR to validate range (20 periods for average)
   if(CopyBuffer(handleATR_M5, 0, 1, 20, atr) < 20) {
      PrintFormat(">> [RANGE DEBUG] Error copying ATR");
      return 0;
   }
   
   // RSI filter for overbought/oversold
   if(CopyBuffer(handleRSI_M5, 0, 1, 1, rsi) < 1) {
      PrintFormat(">> [RANGE DEBUG] Error copying RSI");
      return 0;
   }
   
   double rsi_now = rsi[0];  // Current RSI
   
   // ⚠️ CRITICAL: Correct indices for CURRENT (most recent) values
   // CopyHigh/Low/Close/Open(..., 0, 2, array) = array[0] = bar 1 (current), array[1] = bar 2 (previous)
   // To compare rejection: array[0] = current candle, array[1] = previous candle
   
   double bb_upper_now = bb_upper[1];    // ✅ Current upper band
   double bb_lower_now = bb_lower[1];    // ✅ Current lower band
   double bb_middle_now = bb_middle[1];  // ✅ Current middle band
   
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
   
   // Dynamic ATR - calculate average of last 20 periods
   double atr_now = atr[19];             // ✅ ATR mais recente (bar 20)
   double atr_avg = 0;
   for(int i = 0; i < 20; i++) {
      atr_avg += atr[i];
   }
   atr_avg /= 20;
   
   // Range filter: ATR < 85% of average = market with low volatility
   bool allowRange = (atr_now < atr_avg * 0.85);
   
   // Pre-breakout filter: ATR > 110% of average = increasing volatility, block RANGE
   bool blockRange = (atr_now > atr_avg * 1.1);
   
   // Rejection filter: validate real rejection candle (not just position)
   // BULLISH Rejection: High[0] > High[1] (new high) && Close[0] < Open[0] (closes below opening)
   bool rejectionBullish = (high_now > high_prev && close_now < open_now);
   
   // BEARISH Rejection: Low[0] < Low[1] (new low) && Close[0] > Open[0] (closes above opening)
   bool rejectionBearish = (low_now < low_prev && close_now > open_now);
   
   // Mean Reversion Strategy for WIN M5 RANGE:
   // Operates when price is far from average (minimum 25% of band_range for expanded entry zone)
   double band_range = bb_upper_now - bb_lower_now;
   double distance_from_middle = close_now - bb_middle_now;
   double min_distance_threshold = band_range * 0.25;  // 25% of range (expanded entry zone)

   bool ema_cross_condition = (MathAbs(distance_from_middle) >= min_distance_threshold);
   bool adx_condition = (!blockRange);  // reuse flag to avoid high-vol breakout
   bool atr_growth_condition = allowRange;  // ATR needs to be inside range filter
   bool h1_bias_condition = true;  // No H1 bias in range model
   bool pullback_condition = (rejectionBullish || rejectionBearish);  // rejection acts as pullback proxy
   
   PrintFormat(">> [RANGE DEBUG] BBupper=%.5f BBmiddle=%.5f BBlower=%.5f | High=%.5f Low=%.5f Close=%.5f Open=%.5f", 
               bb_upper_now, bb_middle_now, bb_lower_now, high_now, low_now, close_now, open_now);
   PrintFormat(">> [RANGE DEBUG] ATR=%.0f ATRaverage=%.0f | RSI=%.2f | Range? %s (ATR < 85%%) | Pre-Breakout? %s (ATR > 110%%)",
               atr_now, atr_avg, rsi_now, allowRange ? "YES" : "NO", blockRange ? "YES" : "NO");
   PrintFormat(">> [RANGE DEBUG] Bullish Rejection? %s (High[0]=%.5f > High[1]=%.5f && Close=%.5f < Open=%.5f)", 
               rejectionBullish ? "YES" : "NO", high_now, high_prev, close_now, open_now);
   PrintFormat(">> [RANGE DEBUG] Bearish Rejection? %s (Low[0]=%.5f < Low[1]=%.5f && Close=%.5f > Open=%.5f)", 
               rejectionBearish ? "YES" : "NO", low_now, low_prev, close_now, open_now);
   PrintFormat(">> [RANGE DEBUG] Distance: %.0f | Min Threshold: %.0f | Close < Average-25%%? %s | Close > Average+25%%? %s",
               MathAbs(distance_from_middle), min_distance_threshold,
               (close_now < bb_middle_now - min_distance_threshold ? "YES" : "NO"),
               (close_now > bb_middle_now + min_distance_threshold ? "YES" : "NO"));
   
   // BUY: Close BELOW average (min 25%) + bullish rejection + range ATR + NOT in pre-breakout + RSI < 30
   if(!blockRange && allowRange && close_now < bb_middle_now - min_distance_threshold && rejectionBullish && rsi_now < 30.0) {
      PrintFormat(">> RANGE BUY Signal: Close=%.5f < Average-25%%=%.5f (dist=%.0f) + bullish rejection (High>High[1] && Close<Open) + range ATR + RSI=%.2f < 30", 
                  close_now, bb_middle_now - min_distance_threshold, MathAbs(distance_from_middle), rsi_now);
      return +1;
   }
   
   // SELL: Close ABOVE average (min 25%) + bearish rejection + range ATR + NOT in pre-breakout + RSI > 70
   if(!blockRange && allowRange && close_now > bb_middle_now + min_distance_threshold && rejectionBearish && rsi_now > 70.0) {
      PrintFormat(">> RANGE SELL Signal: Close=%.5f > Average+25%%=%.5f (dist=%.0f) + bearish rejection (Low<Low[1] && Close>Open) + range ATR + RSI=%.2f > 70", 
                  close_now, bb_middle_now + min_distance_threshold, MathAbs(distance_from_middle), rsi_now);
      return -1;
   }
   
   if(!ema_cross_condition) {
      PrintFormat(">> [BLOCK] EMA cross falhou (DistFromMid=%.0f < MinThreshold=%.0f)", MathAbs(distance_from_middle), min_distance_threshold);
   }
   if(!adx_condition) {
      PrintFormat(">> [BLOCK] ADX baixo (Range bloqueado por volatilidade alta - ATR>110%%)");
   }
   if(!atr_growth_condition) {
      PrintFormat(">> [BLOCK] ATR não cresceu suficiente (ATR=%.0f >= Avg*0.85=%.0f)", atr_now, atr_avg * 0.85);
   }
   if(!h1_bias_condition) {
      PrintFormat(">> [BLOCK] Viés H1 não alinhado (não aplicável no RANGE)");
   }
   if(!pullback_condition) {
      PrintFormat(">> [BLOCK] Pullback não ocorreu (Sem candle de rejeição)");
   }

   PrintFormat(">> [RANGE DEBUG] No signal generated");
   
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
      PrintFormat(">> Warning: Volume unavailable for Breakout, using only price and ATR");
      // Continuar sem volume
   }
   
   // Calcular range de consolidação (excluindo o candle atual)
   // ✅ Donchian Channel: Define o range de consolidação
   // Upper Band = Máximo dos últimos N períodos (Breakout_ConsolidationBars)
   // Lower Band = Mínimo dos últimos N períodos (Breakout_ConsolidationBars)
   // Middle Band = (Upper + Lower) / 2
   
   // Calcular Donchian Channel
   double donchianUpper = high[1];  // Iniciar com o primeiro valor
   double donchianLower = low[1];
   
   for(int i = 2; i <= Breakout_ConsolidationBars; i++) {
      if(high[i] > donchianUpper) donchianUpper = high[i];
      if(low[i] < donchianLower) donchianLower = low[i];
   }
   
   double donchianMiddle = (donchianUpper + donchianLower) / 2.0;
   double donchianRange = donchianUpper - donchianLower;
   
   // Referências para análise de breakout
   double highPrev = high[1];  // High do candle anterior (índice 1)
   double lowPrev = low[1];    // Low do candle anterior (índice 1)
   
   // ATR médio
   double avgATR = 0;
   for(int i = 0; i < Breakout_ConsolidationBars; i++) {
      if(atr[i] <= 0) {
         PrintFormat(">> Invalid ATR in Breakout at index %d: %.5f", i, atr[i]);
         return 0;
      }
      avgATR += atr[i];
   }
   avgATR /= Breakout_ConsolidationBars;
   
   // Índices corretos para candle ATUAL
   double currentClose = close[Breakout_ConsolidationBars];
   double currentATR = atr[Breakout_ConsolidationBars - 1];

   bool atr_growth_condition = (currentATR > avgATR);
   
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

   bool ema_cross_condition = false;  // Will be set after breakoutUp/down calc
   bool adx_condition = true;         // ADX not used in breakout model
   bool h1_bias_condition = true;     // H1 bias not used here
   
   PrintFormat(">> [BREAKOUT DEBUG] Close=%.5f | Donchian Upper=%.5f Middle=%.5f Lower=%.5f Range=%.0f | ATR=%.0f(Avg=%.0f) | Vol=%.0f(Avg=%.0f) | BreakoutWaiting=%s(Dir:%d)", 
               currentClose, donchianUpper, donchianMiddle, donchianLower, donchianRange, currentATR, avgATR, currentVolume, avgVolume, breakoutConfirmed ? "SIM" : "NÃO", breakoutDirection);
   
   // Detectar confirmação de rompimento usando Donchian Channel
   bool breakoutUp = currentClose > donchianUpper + (currentATR * 0.1);
   bool breakoutDown = currentClose < donchianLower - (currentATR * 0.1);
   ema_cross_condition = breakoutUp || breakoutDown;
   
   //=== ESTÁGIO 1: DETECTAR ROMPIMENTO COM SISTEMA DE SCORE ===
   if(!breakoutConfirmed && currentATR > avgATR) {
      // ROMPIMENTO PARA CIMA - Sistema de Score (acima da Donchian Upper Band)
      if(breakoutUp) {
         int scoreUp = 0;
         
         // Score 1: ATR expandindo
         if(currentATR > avgATR) scoreUp++;
         
         // Score 2: Volume acima da média (1.8x)
         if(currentVolume > avgVolume * Breakout_VolumeMultiplier) scoreUp++;
         
         // Score 3: Close acima do High anterior
         if(currentClose > highPrev) scoreUp++;
         
         PrintFormat(">> [BREAKOUT SCORE UP] Close=%.5f > Donchian Upper(%.5f) + ATR*0.1 | Score=%d/3 (ATR:%s | Vol:%.0f>%.0f*%.1fx=%s | ClosePrev:%s)",
                     currentClose, donchianUpper, scoreUp,
                     (currentATR > avgATR ? "✓" : "✗"),
                     currentVolume, avgVolume, Breakout_VolumeMultiplier,
                     (currentVolume > avgVolume * Breakout_VolumeMultiplier ? "✓" : "✗"),
                     (currentClose > highPrev ? "✓" : "✗"));
         
         if(scoreUp >= 2) {
            PrintFormat(">> [BREAKOUT CONFIRMATION] ROMPIMENTO UP detectado! Score=%d/3", scoreUp);
            PrintFormat("   Close=%.5f > Donchian Upper(%.5f) + ATR(%.0f)*0.1", currentClose, donchianUpper, currentATR);
            
            breakoutConfirmed = true;
            breakoutDirection = +1;
            breakoutLevel = donchianUpper;
            breakoutATR = currentATR;
            breakoutPullbackAttempts = 0;  // Reset contador de tentativas
            
            // Colocar ordem LIMIT imediatamente no nível de rompimento com filtro de 15 pontos
            double limitPriceWithFilter = NormalizePrice(breakoutLevel + 15 * _Point);
            PrintFormat("   Placing IMMEDIATE LIMIT BUY order at level=%.5f (breakout + 15pts)", limitPriceWithFilter);
            
            if(PlaceBreakoutLimitOrder(true, limitPriceWithFilter)) {
               breakoutPullbackAttempts = 1;  // Marcar que ordem foi colocada
               PrintFormat(">> [BREAKOUT LIMIT] Limit BUY order placed successfully. Waiting for pullback and execution...");
            } else {
               PrintFormat(">> [BREAKOUT LIMIT] Failed to place order. Will try again on pullback.");
            }
            
            return 0;
         }
      }
      
      // ROMPIMENTO PARA BAIXO - Sistema de Score (abaixo da Donchian Lower Band)
      if(breakoutDown) {
         int scoreDown = 0;
         
         // Score 1: ATR expandindo
         if(currentATR > avgATR) scoreDown++;
         
         // Score 2: Volume acima da média (1.8x)
         if(currentVolume > avgVolume * Breakout_VolumeMultiplier) scoreDown++;
         
         // Score 3: Close abaixo do Low anterior
         if(currentClose < lowPrev) scoreDown++;
         
         PrintFormat(">> [BREAKOUT SCORE DOWN] Close=%.5f < Donchian Lower(%.5f) - ATR*0.1 | Score=%d/3 (ATR:%s | Vol:%.0f>%.0f*%.1fx=%s | ClosePrev:%s)",
                     currentClose, donchianLower, scoreDown,
                     (currentATR > avgATR ? "✓" : "✗"),
                     currentVolume, avgVolume, Breakout_VolumeMultiplier,
                     (currentVolume > avgVolume * Breakout_VolumeMultiplier ? "✓" : "✗"),
                     (currentClose < lowPrev ? "✓" : "✗"));
         
         if(scoreDown >= 2) {
            PrintFormat(">> [BREAKOUT CONFIRMATION] ROMPIMENTO DOWN detectado! Score=%d/3", scoreDown);
            PrintFormat("   Close=%.5f < Donchian Lower(%.5f) - ATR(%.0f)*0.1", currentClose, donchianLower, currentATR);
            
            breakoutConfirmed = true;
            breakoutDirection = -1;
            breakoutLevel = donchianLower;
            breakoutATR = currentATR;
            breakoutPullbackAttempts = 0;  // Reset contador de tentativas
            
            // Colocar ordem LIMIT imediatamente no nível de rompimento com filtro de 15 pontos
            double limitPriceWithFilter = NormalizePrice(breakoutLevel - 15 * _Point);
            PrintFormat("   Placing IMMEDIATE LIMIT SELL order at level=%.5f (breakout - 15pts)", limitPriceWithFilter);
            
            if(PlaceBreakoutLimitOrder(false, limitPriceWithFilter)) {
               breakoutPullbackAttempts = 1;  // Marcar que ordem foi colocada
               PrintFormat(">> [BREAKOUT LIMIT] Limit SELL order placed successfully. Waiting for pullback and execution...");
            } else {
               PrintFormat(">> [BREAKOUT LIMIT] Failed to place order. Will try again on pullback.");
            }
            
            return 0;
         }
      }
   }
   if(!breakoutConfirmed) {
      if(!ema_cross_condition) {
         PrintFormat(">> [BLOCK] EMA cross falhou (Close=%.5f | DonchianUpper=%.5f | DonchianLower=%.5f)", currentClose, donchianUpper, donchianLower);
      }
      if(!adx_condition) {
         Print(">> [BLOCK] ADX baixo");
      }
      if(!atr_growth_condition) {
         PrintFormat(">> [BLOCK] ATR não cresceu suficiente (ATR=%.0f <= Avg=%.0f)", currentATR, avgATR);
      }
      if(!h1_bias_condition) {
         Print(">> [BLOCK] Viés H1 não alinhado (não aplicável no BREAKOUT)");
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
         
         // Se já colocou ordem limit (attempts=1), apenas aguardar execução
         if(breakoutPullbackAttempts >= 1) {
            // Verificar se ordem ainda existe
            if(breakoutLimitOrderTicket > 0 && OrderSelect(breakoutLimitOrderTicket)) {
               PrintFormat(">> [BREAKOUT LIMIT] Order #%d waiting for execution...", breakoutLimitOrderTicket);
            } else {
               PrintFormat(">> [BREAKOUT BLOCKED] Limit order não existe mais ou já foi executada.");
            }
         }
         // Se Close volta para zona de pullback e ainda não colocou ordem limit
         else if(currentClose <= upperPullbackZone && currentClose >= lowerPullbackZone) {
            breakoutPullbackAttempts++;  // Incrementar tentativa
            
            // Colocar ordem LIMIT no nível do rompimento (melhor preço) com filtro
            double limitPriceWithFilter = NormalizePrice(breakoutLevel + 15 * _Point);
            PrintFormat(">> [BREAKOUT PULLBACK] Placing LIMIT BUY order at breakout level: %.5f (+ 15pts)", limitPriceWithFilter);
            PrintFormat("   Close=%.5f entrou na zona [%.5f, %.5f]", 
                        currentClose, lowerPullbackZone, upperPullbackZone);
            
            if(PlaceBreakoutLimitOrder(true, limitPriceWithFilter)) {
               PrintFormat(">> [BREAKOUT LIMIT] Limit BUY order placed. Waiting for execution...");
               // NÃO resetar aqui - ordem limit ficará pendente
               // return 0 para não entrar com market order
               return 0;
            } else {
               // Se falhou ao colocar ordem, resetar
               breakoutConfirmed = false;
               breakoutDirection = 0;
               breakoutLevel = 0;
               breakoutATR = 0;
               breakoutPullbackAttempts = 0;
            }
         }
         else {
            PrintFormat(">> [BLOCK] Pullback não ocorreu (Close=%.5f | Zone=[%.5f, %.5f])", 
                        currentClose, lowerPullbackZone, upperPullbackZone);
         }
         
         // Se Close voltou abaixo do nível (pullback terminou sem entrada), cancelar ordem e resetar
         if(currentClose < breakoutLevel - pullbackZoneMargin) {
            PrintFormat(">> [BREAKOUT PULLBACK EXPIRED] Pullback para cima expirou (Tentativas: %d/1). Resetando...", breakoutPullbackAttempts);
            CancelBreakoutLimitOrder("Pullback expirado");
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
         
         // Se já colocou ordem limit (attempts=1), apenas aguardar execução
         if(breakoutPullbackAttempts >= 1) {
            // Verificar se ordem ainda existe
            if(breakoutLimitOrderTicket > 0 && OrderSelect(breakoutLimitOrderTicket)) {
               PrintFormat(">> [BREAKOUT LIMIT] Order #%d waiting for execution...", breakoutLimitOrderTicket);
            } else {
               PrintFormat(">> [BREAKOUT BLOCKED] Limit order não existe mais ou já foi executada.");
            }
         }
         // Se Close volta para zona de pullback e ainda não colocou ordem limit
         else if(currentClose >= lowerPullbackZone && currentClose <= upperPullbackZone) {
            breakoutPullbackAttempts++;  // Incrementar tentativa
            
            // Colocar ordem LIMIT no nível do rompimento (melhor preço) com filtro
            double limitPriceWithFilter = NormalizePrice(breakoutLevel - 15 * _Point);
            PrintFormat(">> [BREAKOUT PULLBACK] Placing LIMIT SELL order at breakout level: %.5f (- 15pts)", limitPriceWithFilter);
            PrintFormat("   Close=%.5f entrou na zona [%.5f, %.5f]", 
                        currentClose, lowerPullbackZone, upperPullbackZone);
            
            if(PlaceBreakoutLimitOrder(false, limitPriceWithFilter)) {
               PrintFormat(">> [BREAKOUT LIMIT] Limit SELL order placed. Waiting for execution...");
               // NÃO resetar aqui - ordem limit ficará pendente
               // return 0 para não entrar com market order
               return 0;
            } else {
               // Se falhou ao colocar ordem, resetar
               breakoutConfirmed = false;
               breakoutDirection = 0;
               breakoutLevel = 0;
               breakoutATR = 0;
               breakoutPullbackAttempts = 0;
            }
         }
         
         // Se Close voltou acima do nível (pullback terminou sem entrada), cancelar ordem e resetar
         if(currentClose > breakoutLevel + pullbackZoneMargin) {
            PrintFormat(">> [BREAKOUT PULLBACK EXPIRED] Pullback para baixo expirou (Tentativas: %d/1). Resetando...", breakoutPullbackAttempts);
            CancelBreakoutLimitOrder("Pullback expirado");
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
//| Calculate Daily Loss in Points                                  |
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
//| Coloca Ordem Limit para Breakout no Pullback                     |
//+------------------------------------------------------------------+
bool PlaceBreakoutLimitOrder(bool isBuy, double limitPrice) {
   // Verificar se já existe posição aberta ou ordem pendente
   if(PositionSelect(_Symbol)) {
      PrintFormat(">> [BREAKOUT LIMIT] Position already open. Limit order canceled.");
      return false;
   }
   
   // Verificar se já existe ordem limit pendente
   if(breakoutLimitOrderTicket > 0) {
      if(OrderSelect(breakoutLimitOrderTicket)) {
         PrintFormat(">> [BREAKOUT LIMIT] Limit order already exists (Ticket #%d)", breakoutLimitOrderTicket);
         return true;
      } else {
         breakoutLimitOrderTicket = 0;  // Reset se ordem não existe mais
      }
   }
   
   // Calcular SL e TP
   double slPoints, tpPoints, riskReward;
   CalculateStopAndTP(isBuy, slPoints, tpPoints, riskReward);
   
   double slPrice, tpPrice;
   if(isBuy) {
      slPrice = NormalizePrice(limitPrice - slPoints * _Point);
      tpPrice = NormalizePrice(limitPrice + tpPoints * _Point);
   } else {
      slPrice = NormalizePrice(limitPrice + slPoints * _Point);
      tpPrice = NormalizePrice(limitPrice - tpPoints * _Point);
   }
   
   // Validar stops
   if(!ValidateStops(isBuy, limitPrice, slPrice, tpPrice)) {
      PrintFormat(">> [BREAKOUT LIMIT] Invalid stops. Order canceled.");
      return false;
   }
   
   double lotSize = CalculateLotSize(slPoints);
   
   PrintFormat("========================================");
   PrintFormat(">>> BREAKOUT LIMIT ORDER (%s) <<<", isBuy ? "COMPRA" : "VENDA");
   PrintFormat("Limit Price: %.5f (breakout level)", limitPrice);
   PrintFormat("SL=%.0f pts | TP=%.0f pts | R:R=%.2f", slPoints, tpPoints, riskReward);
   PrintFormat("SL Price=%.5f | TP Price=%.5f", slPrice, tpPrice);
   PrintFormat("Lote=%.2f", lotSize);
   PrintFormat("========================================");
   
   // Criar comentário com regime e modelo
   string comment = "MR_" + currentRegimeStr + "_BREAKOUT";
   
   // Colocar ordem limit
   bool result;
   if(isBuy) {
      result = trade.BuyLimit(lotSize, limitPrice, _Symbol, slPrice, tpPrice, 0, 0, comment);
   } else {
      result = trade.SellLimit(lotSize, limitPrice, _Symbol, slPrice, tpPrice, 0, 0, comment);
   }
   
   if(result) {
      breakoutLimitOrderTicket = trade.ResultOrder();
      PrintFormat(">> [BREAKOUT LIMIT] Limit order placed successfully! Ticket #%d", breakoutLimitOrderTicket);
      return true;
   } else {
      PrintFormat(">> [BREAKOUT LIMIT] Error placing order: %s (code: %d)", 
                  trade.ResultRetcodeDescription(), trade.ResultRetcode());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Cancela Ordem Limit de Breakout                                  |
//+------------------------------------------------------------------+
void CancelBreakoutLimitOrder(string reason) {
   if(breakoutLimitOrderTicket > 0) {
      if(OrderSelect(breakoutLimitOrderTicket)) {
         if(trade.OrderDelete(breakoutLimitOrderTicket)) {
            PrintFormat(">> [BREAKOUT LIMIT] Order #%d canceled. Reason: %s", breakoutLimitOrderTicket, reason);
         } else {
            PrintFormat(">> [BREAKOUT LIMIT] Error canceling order #%d: %s", 
                        breakoutLimitOrderTicket, trade.ResultRetcodeDescription());
         }
      }
      breakoutLimitOrderTicket = 0;
   }
}

//+------------------------------------------------------------------+
//| Check Daily Loss Limit                                           |
//+------------------------------------------------------------------+
bool IsWithinDailyLossLimit() {
   dailyLossInPoints = CalculateDailyLossInPoints();
   
   if(dailyLossInPoints >= DailyLossLimit) {
      if(!tradingBlocked) {
         PrintFormat("=== DAILY LOSS LIMIT REACHED ===");
         PrintFormat("Loss: %.0f / Limit: %.0f points", dailyLossInPoints, DailyLossLimit);
         PrintFormat("Trading blocked until next day!");
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
//| Check if in cooldown period after Stop Loss                      |
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
      PrintFormat(">> [COOLDOWN] Waiting: %d min %d sec (last SL at %s)", 
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
      PrintFormat(">> [ONE-TRADE-BAR] Trade already open on this candle");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check if trade direction is allowed (after SL)                   |
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
      PrintFormat(">> [DIRECTION-BLOCK] Same direction (%s) blocked. Time remaining: %d sec", 
                  tradeDirection > 0 ? "COMPRA" : "VENDA", 
                  cooldownSeconds - secondsElapsed);
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check Valid Reasons to Close Position                            |
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
//| Position Management with Minimum Delay                           |
//+------------------------------------------------------------------+
// IMPORTANT: This function does NOT close position on regime change!
// Position is closed ONLY when:
//   - Stop Loss is hit (SL hit)
//   - Take Profit is hit (TP hit)
// Management here includes: Break-Even and Trailing Stop
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
      PrintFormat(">> Position opened at: %s | Regime: %s | Regime change will NOT close", 
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
         PrintFormat(">> [MIN CLOSURE REACHED] Position reached minimum closure profit: %.2f points", 
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
         PrintFormat(">> Break-Even activated after %d candles (Buy)", barsAtPositionOpen);
      }
      
      // Trailing Stop com delay mínimo E validação de lucro mínimo
      if(currentProfit >= tpDistance * TrailingStart && 
         barsAtPositionOpen >= MinDelayTrailingBars && minClosureProfitReached) {
         double newSL = bid - (tpDistance * TrailingStep);
         if(newSL > sl + 10 * _Point) {
            trade.PositionModify(_Symbol, NormalizePrice(newSL), tp);
            PrintFormat(">> Trailing Stop activated after %d candles (Buy) | New SL: %.5f", 
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
         PrintFormat(">> Break-Even activated after %d candles (Sell)", barsAtPositionOpen);
      }
      
      // Trailing Stop com delay mínimo E validação de lucro mínimo
      if(currentProfit >= tpDistance * TrailingStart && 
         barsAtPositionOpen >= MinDelayTrailingBars && minClosureProfitReached) {
         double newSL = ask + (tpDistance * TrailingStep);
         if((newSL < sl - 10 * _Point) || sl == 0) {
            trade.PositionModify(_Symbol, NormalizePrice(newSL), tp);
            PrintFormat(">> Trailing Stop activated after %d candles (Sell) | New SL: %.5f", 
                        barsAtPositionOpen, newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Initialization                                                   |
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
   handleRSI_M5 = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);  // RSI(14) no M5
   
   // Indicadores H1
   handleEMA_H1 = iMA(_Symbol, PERIOD_H1, Trend_EMA_H1, 0, MODE_EMA, PRICE_CLOSE);
   handleATR_H1 = iATR(_Symbol, PERIOD_H1, ATR_Period);
   
   if(handleATR_M5 == INVALID_HANDLE || handleEMA_Fast_M5 == INVALID_HANDLE || 
      handleEMA_Slow_M5 == INVALID_HANDLE || handleBB_M5 == INVALID_HANDLE ||
      handleStoch_M5 == INVALID_HANDLE || handleEMA_H1 == INVALID_HANDLE ||
      handleATR_H1 == INVALID_HANDLE || handleADX_M5 == INVALID_HANDLE ||
      handleRSI_M5 == INVALID_HANDLE) {
      Print(">> ERRO: Falha ao criar indicadores!");
      return INIT_FAILED;
   }
   
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   lastDay = tm.day;
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   trade.SetAsyncMode(false);
   
   Print("========================================");
   Print("=== MarketRegime v1.0 ===");
   Print("========================================");
   PrintFormat("Magic Number: %d", MagicNumber);
   PrintFormat("Modelos Ativos:");
   PrintFormat(" - TREND Following: %s", UseTrendModel ? "YES" : "NO");
   PrintFormat(" - RANGE Reversion: %s", UseRangeModel ? "YES" : "NO");
   PrintFormat(" - BREAKOUT: %s", UseBreakoutModel ? "YES" : "NO");
   PrintFormat("Daily Loss Limit: %.0f pontos", DailyLossLimit);
   Print("========================================");
   
   Sleep(1000);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Main Execution                                                    |
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
      PrintFormat(">> [FILTER] Trading BLOCKED (daily loss limit reached)");
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
      PrintFormat(">> [FILTER] Daily loss limit reached");
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
         PrintFormat(">> BUY order canceled: invalid stops");
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
      
      string comment = "MR_" + currentRegimeStr + "_" + modelName;
      if(trade.Buy(lotSize, _Symbol, ask, slPrice, tpPrice, comment)) {
         Print(">> COMPRA EXECUTADA COM SUCESSO");
         // Registrar timestamp do candle do trade para OneTradePerBar
         lastTradeBarTime = iTime(_Symbol, PERIOD_M5, 0);
         
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
         PrintFormat(">> SELL order canceled: invalid stops");
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
      
      string comment = "MR_" + currentRegimeStr + "_" + modelName;
      if(trade.Sell(lotSize, _Symbol, bid, slPrice, tpPrice, comment)) {
         Print(">> VENDA EXECUTADA COM SUCESSO");
         // Registrar timestamp do candle do trade para OneTradePerBar
         lastTradeBarTime = iTime(_Symbol, PERIOD_M5, 0);
         
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
   // Detectar quando ordem limit de breakout é executada
   if(trans.type == TRADE_TRANSACTION_ORDER_DELETE && breakoutLimitOrderTicket > 0 && trans.order == breakoutLimitOrderTicket) {
      // Verificar se ordem foi executada (virou posição) ou cancelada
      if(OrderSelect(breakoutLimitOrderTicket)) {
         long orderState = OrderGetInteger(ORDER_STATE);
         if(orderState == ORDER_STATE_FILLED) {
            PrintFormat(">> [BREAKOUT LIMIT] Order #%d EXECUTED! Position opened.", breakoutLimitOrderTicket);
            // Resetar variáveis de breakout
            breakoutConfirmed = false;
            breakoutDirection = 0;
            breakoutLevel = 0;
            breakoutATR = 0;
            breakoutPullbackAttempts = 0;
            breakoutLimitOrderTicket = 0;
            
            // Registrar timestamp do candle do trade para OneTradePerBar
            lastTradeBarTime = iTime(_Symbol, PERIOD_M5, 0);
         }
      }
   }
   
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal)) {
      long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      
      // Detectar se deal foi resultado da ordem limit de breakout
      if(entry == DEAL_ENTRY_IN && breakoutLimitOrderTicket > 0) {
         long dealOrderTicket = HistoryDealGetInteger(trans.deal, DEAL_ORDER);
         if(dealOrderTicket == breakoutLimitOrderTicket) {
            PrintFormat(">> [BREAKOUT LIMIT] Limit order #%d executed via deal! Position opened.", breakoutLimitOrderTicket);
            // Resetar variáveis de breakout
            breakoutConfirmed = false;
            breakoutDirection = 0;
            breakoutLevel = 0;
            breakoutATR = 0;
            breakoutPullbackAttempts = 0;
            breakoutLimitOrderTicket = 0;
         }
      }
      
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
         PrintFormat("Loss: %.2f", profit);
         PrintFormat("Direction: %s | Cooldown initiated: %d minutes", 
                     lastStopLossDirection > 0 ? "COMPRA" : "VENDA", 
                     CooldownMinutesAfterSL);
         PrintFormat("=========================");
      }
      
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) {
         double volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
         
         string result = profit >= 0 ? "> GAIN" : "< LOSS";
         PrintFormat("==============================");
         PrintFormat("TRADE FECHADO: %.2f %s", profit, result);
         PrintFormat("Volume: %.2f | Price: %.2f", 
                     volume, HistoryDealGetDouble(trans.deal, DEAL_PRICE));
         PrintFormat("==============================");
         
         // Resetar flag de lucro mínimo quando posição é fechada
         minClosureProfitReached = false;
         PrintFormat(">> [MIN CLOSURE] Flag reset for next position");
      }
   }
}