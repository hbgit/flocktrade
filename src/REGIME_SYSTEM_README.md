# 📊 MarketRegime
## Adaptive System by MARKET REGIME

---

## 🎯 SYSTEM ARCHITECTURE

The EA now operates with a **REGIME DETECTOR** as its central core, automatically identifying market conditions and activating the most suitable specific model.

```
┌─────────────────────────────────────────────────┐
│         🔍 REGIME DETECTOR (CORE)              │
│                                                 │
│  Analyzes: ATR, Directionality, Range,         │
│            EMAs, Volume                         │
├─────────────────────────────────────────────────┤
│                                                 │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐       │
│   │  TREND  │  │  RANGE  │  │BREAKOUT │       │
│   └─────────┘  └─────────┘  └─────────┘       │
│        ↓            ↓             ↓             │
│   Model 1     Model 2       Model 3            │
└─────────────────────────────────────────────────┘
```

---

## 🔍 REGIME DETECTOR

### **Configuration Parameters:**
- `Regime_LookbackBars = 20` - Candles for analysis
- `Regime_TrendThreshold = 0.65` - Directionality threshold (0-1)
- `Regime_RangeATRRatio = 0.7` - Low ATR for range
- `Regime_BreakoutATRRatio = 1.3` - High ATR for breakout

### **Detection Logic:**

1. **BREAKOUT** (High Priority)
   - Current ATR > Average ATR × 1.3
   - Price breaking range extremes
   
2. **RANGE** (Medium Priority)
   - Current ATR < Average ATR × 0.7
   - Directionality < 65%
   - Price oscillating without clear trend
   
3. **TREND** (Low Priority)
   - EMA 9 consistently above/below EMA 21
   - Rising ATR (> average × 1.1)
   - Clear directionality

---

## 📈 MODEL 1: TREND FOLLOWING

**Used when:** Directional market with rising ATR

### **Indicators:**
- ✅ EMA 9 × EMA 21 (M5) - Trend direction
- ✅ EMA 50 or 100 (H1) - Long-term bias
- ✅ ATR(14) rising - Momentum confirmation

### **Entry Rules:**

**BUY:**
```
- EMA9 > EMA21 (both recent candles)
- Current ATR > Average ATR × 1.1
- Price above H1 EMA
```

**SELL:**
```
- EMA9 < EMA21 (both recent candles)
- Current ATR > Average ATR × 1.1
- Price below H1 EMA
```

### **Management:**
- **Stop Loss:** ATR × 2.5 or last swing low/high
- **Take Profit:** Partial (50% at TP1) + Trailing
- **R:R:** 2.0 (configurable)

### **Characteristics:**
- ❌ Does NOT use Bollinger Bands
- ❌ Does NOT use RSI
- ❌ Does NOT use Stochastic
- ✅ Focus on following directional momentum

---

## 🔄 MODEL 2: MEAN REVERSION (RANGE)

**Used when:** Clear ranging with low ATR

### **Indicators:**
- ✅ Bollinger Bands (20, 2.0)
- ✅ Stochastic (14, 3, 3)
- ✅ Low ATR

### **Entry Rules:**

**BUY:**
```
- Touch lower band
- Stochastic < 20
- Upward Stoch crossover (%K crosses %D)
- Rejection candle (close > low)
```

**SELL:**
```
- Touch upper band
- Stochastic > 80
- Downward Stoch crossover (%K crosses %D)
- Rejection candle (close < high)
```

### **Management:**
- **Stop Loss:** Outside band × 1.2
- **Take Profit:** VWAP or BB middle
- **R:R:** 1.5 (configurable)

### **Characteristics:**
- ❌ Does NOT use EMA cross
- ❌ Does NOT use momentum
- ✅ Focus on mean reversion

---

## 💥 MODEL 3: BREAKOUT

**Used when:** Volatility expansion after consolidation

### **Indicators:**
- ✅ Consolidation range (last N candles)
- ✅ ATR compressed → expansion
- ✅ Volume above average

### **Entry Rules:**

**BUY:**
```
- Break above range high
- Close outside range
- Volume > Average × 1.5
- ATR expanding
```

**SELL:**
```
- Break below range low
- Close outside range
- Volume > Average × 1.5
- ATR expanding
```

### **Management:**
- **Stop Loss:** Inside broken range (ATR × 2.0)
- **Take Profit:** Full extension
- **R:R:** 2.5 (configurable)

### **Characteristics:**
- ❌ Does NOT use RSI
- ❌ Does NOT use Stochastic
- ✅ Focus on capturing explosive moves

---

## ⚙️ POSITION MANAGEMENT

### **Break-Even:**
- Activation: 60% of TP reached
- Minimum delay: 5 candles
- Offset: 50% of current profit

### **Trailing Stop:**
- Activation: 60% of TP reached
- Minimum delay: 8 candles
- Step: 30% of movement

### **Partial Exit (TREND Model):**
- 50% of position at TP1
- Remainder with aggressive trailing

---

## 📊 RISK CONTROL

- **Risk per trade:** 1% of capital
- **Daily loss limit:** 250 points
- **Maximum spread:** 10 points or 20% of SL
- **Trading hours:** 10am-11am and 2pm-4pm

---

## 🔧 MAIN PARAMETERS

### **TREND Model:**
```
Trend_EMA_Fast = 9
Trend_EMA_Slow = 21
Trend_EMA_H1 = 50
Trend_ATR_Growth = 1.1
Trend_RiskReward = 2.0
```

### **RANGE Model:**
```
Range_BB_Period = 20
Range_BB_Deviation = 2.0
Range_Stoch_K = 14
Range_RiskReward = 1.5
```

### **BREAKOUT Model:**
```
Breakout_ConsolidationBars = 15
Breakout_VolumeMultiplier = 1.5
Breakout_RiskReward = 2.5
```

---

## 📝 SYSTEM LOGS

The EA displays detailed logs:

```
========================================
REGIME DETECTED: TREND
========================================

========================================
>>> BUY SETUP <<<
Regime: TREND | Model: TREND FOLLOWING
SL=150 pts | TP=300 pts | R:R=2.00
Lot=0.10 | Spread=2 pts
========================================
>> BUY EXECUTED SUCCESSFULLY

>> Break-Even activated after 5 candles (Buy)
>> Trailing Stop activated after 8 candles (Buy) | New SL: 1.08450
```

---

## ✅ SYSTEM ADVANTAGES

1. **Adaptability:** Automatically adjusts to market regime
2. **Specialization:** Each model uses only appropriate indicators
3. **Efficiency:** Avoids conflicting signals
4. **Transparency:** Clear logs about decisions
5. **Robustness:** Multiple layers of risk protection

---

## 🚀 NEXT STEPS

1. **Backtest** each regime separately
2. **Optimization** of detection thresholds
3. **Validation** on different assets and timeframes
4. **Machine Learning** for regime detection (future)

---

**Version:** 2.0  
**Date:** January 2026  
**Author:** hbgit
