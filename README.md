# Flocktrade

## Overview

Flocktrade is an advanced algorithmic trading platform featuring two distinct Expert Advisors built with MQL5 (MetaTrader 5). The project offers two complementary approaches to systematic trading:

1. **MarketRegime** - Adaptive system that detects market conditions and applies specialized strategies
2. **StatisticalEdge** - Multi-model ensemble approach using weighted voting for consensus-based signals

Both systems incorporate sophisticated risk management, dynamic position sizing, and adaptive stop-loss mechanisms.

---

## 📊 MarketRegime.mq5

### Core Architecture

MarketRegime operates with a **REGIME DETECTOR** as its central intelligence, automatically identifying market conditions and activating the most suitable trading model:

```
┌─────────────────────────────────────────────────┐
│         🔍 REGIME DETECTOR (CORE)              │
│  Analyzes: ATR, Directionality, Range,         │
│            EMAs, Volume, ADX                    │
├─────────────────────────────────────────────────┤
│   ┌─────────┐  ┌─────────┐  ┌─────────┐       │
│   │  TREND  │  │  RANGE  │  │BREAKOUT │       │
│   └─────────┘  └─────────┘  └─────────┘       │
│        ↓            ↓             ↓             │
│   Model 1     Model 2       Model 3            │
└─────────────────────────────────────────────────┘
```

### Trading Models

#### Model 1: TREND FOLLOWING
**Used when:** Directional market with rising ATR and ADX > 25

**Indicators:**
- EMA 9 × EMA 21 (M5) - Trend direction
- EMA 50/100 (H1) - Long-term bias
- ATR(14) rising - Momentum confirmation
- ADX for trend strength validation

**Entry Logic:**
- BUY: EMA9 > EMA21, current ATR > avg × 0.95, price above H1 EMA, ADX > 25
- SELL: EMA9 < EMA21, current ATR > avg × 0.95, price below H1 EMA, ADX > 25

**Management:** R:R 2.0, ATR × 2.5 stop loss, partial exit + trailing

#### Model 2: MEAN REVERSION (RANGE)
**Used when:** Low volatility (ATR < avg × 0.7) and ADX < 20

**Indicators:**
- Bollinger Bands (20, 2.0)
- Stochastic (14, 3, 3)
- Low ATR environment

**Entry Logic:**
- BUY: Touch lower band, Stochastic < 20, upward crossover
- SELL: Touch upper band, Stochastic > 80, downward crossover

**Management:** R:R 1.5, stop outside bands × 1.2

#### Model 3: BREAKOUT
**Used when:** High volatility (ATR > avg × 1.3) after consolidation

**Indicators:**
- Consolidation range detection
- ATR expansion analysis
- Volume confirmation (> avg × 1.5)

**Entry Logic:**
- BUY: Break above range high with volume
- SELL: Break below range low with volume

**Management:** R:R 2.5, stop inside broken range

### Key Features

- **Regime Confirmation:** Requires 2-3 consecutive candles to confirm regime change (hysteresis)
- **Adaptive Risk:** Position sizing based on 1% account risk per trade
- **Daily Loss Limit:** 250 points maximum daily loss
- **Trading Hours:** 10am-1pm and 2pm-5pm sessions
- **Break-Even Protection:** Activated at 30% of TP after 5 bars
- **Trailing Stop:** Starts at 30% of TP after 8 bars
- **Cooldown System:** 15-minute cooldown after stop loss
- **Maximum Spread:** 10 points or 20% of SL

---

## 📈 StatisticalEdge.mq5

### Core Architecture

StatisticalEdge implements a **multi-model consensus strategy** using a weighted voting system. Only when sufficient consensus is reached does the EA execute trades.

### Trading Models

#### Model 1: MEAN REVERSION (Bollinger Bands)
- Identifies overbought/oversold conditions at statistical extremes
- Weight: 1 vote
- Uses BB(20, 2.0) for entry signals

#### Model 2: MOMENTUM (RSI + Volume)
- Detects trend strength with RSI(14) and volume confirmation
- Weight: 1 vote
- Requires volume > avg × 1.5

#### Model 3: STRUCTURE (Support/Resistance)
- Recognizes key price levels and structural breaks
- Weight: 2 votes (highest priority)
- Pivot lookback: 10 bars
- Tolerance: 0.15%

#### Model 4: STOCHASTIC (Oscillator + Divergence)
- Captures momentum reversals and divergence signals
- Weight: 1 vote
- Includes divergence detection algorithm

### Voting System

- **Minimum Votes Required:** 3 weighted votes
- Each model contributes votes based on configured weights
- Confluence approach reduces false signals
- Structure model has double weight (2 votes)

### Key Features

- **Dynamic Stop Loss:** ATR × 2.5 with 100-200 point limits
- **Risk/Reward Ratio:** 1.8 minimum
- **Position Sizing:** Automatic lot calculation based on 1% risk
- **Break-Even:** Activated at 60% of TP after 5 bars
- **Trailing Stop:** Starts at 60% of TP after 8 bars
- **EMA Trend Filter:** Fast(9) × Slow(21) for directional bias
- **Trading Hours:** 10am-11am and 2pm-4pm sessions
- **Daily Loss Limit:** 250 points
- **Maximum Spread:** 10 points or 20% of SL

### Complementary Filters

- ATR minimum multiplier (1.2×) for volatility confirmation
- Spread validation before every trade
- Session-based time filters
- One trade per bar control

---

## 📁 Project Structure

```
flocktrade/
├── LICENSE
├── README.md
└── src/
    ├── MarketRegime.mq5          # Regime-based adaptive system
    ├── StatisticalEdge.mq5        # Multi-model voting system
    └── REGIME_SYSTEM_README.md    # Detailed MarketRegime docs
```

---

## Installation & Usage

### For MarketRegime.mq5:
1. Copy `MarketRegime.mq5` to your MetaTrader 5 Experts folder
2. Compile in MQL5 editor
3. Configure regime detection parameters and model weights
4. Backtest each regime separately for optimization
5. Attach to M5 chart for live trading

### For StatisticalEdge.mq5:
1. Copy `StatisticalEdge.mq5` to your MetaTrader 5 Experts folder
2. Compile in MQL5 editor
3. Configure model weights and minimum votes required
4. Adjust indicator parameters based on asset characteristics
5. Backtest extensively before live deployment

---

## System Comparison

| Feature | MarketRegime | StatisticalEdge |
|---------|--------------|-----------------|
| **Approach** | Regime detection → Model selection | Multi-model voting consensus |
| **Models** | 3 specialized models | 4 weighted models |
| **Adaptability** | High (regime-specific) | Moderate (vote-based) |
| **Complexity** | High (state machine) | Medium (voting system) |
| **Best For** | Varying market conditions | Stable statistical edge |
| **R:R Range** | 1.5 - 2.5 | Fixed at 1.8 |

---

## Risk Management

Both EAs implement comprehensive risk controls:

- **1% Risk per Trade** - Fixed fractional position sizing
- **Daily Loss Limit** - 250 points maximum
- **Dynamic Stops** - ATR-based adaptive stop loss
- **Break-Even Protection** - Automatic profit locking
- **Trailing Stops** - Maximizes winning trades
- **Spread Control** - Prevents excessive slippage
- **Time Filters** - Trades only during optimal sessions

---

## License

See LICENSE file for details.

---

**Version:** 1.00  
**Date:** January 2026  
**Author:** hbgit
