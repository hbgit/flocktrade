# Flocktrade

## Overview

Flocktrade is an advanced algorithmic trading bot built on a **mathematical ensemble approach** using MQL5 (MetaTrader 5 Expert Advisor). This project combines multiple technical analysis models with a weighted voting system to generate robust trading signals with superior risk management.

## Project Description

Flocktrade implements a sophisticated **multi-model consensus strategy** that leverages four distinct technical analysis frameworks:

- **Mean Reversion Model** (Bollinger Bands): Identifies overbought/oversold conditions at statistical extremes
- **Momentum Model** (RSI + Volume Analysis): Detects trend strength using relative strength and volume confirmation
- **Structure Model** (Support/Resistance): Recognizes key price levels and structural breaks
- **Stochastic Model** (Oscillator with Divergence Detection): Captures momentum reversals and divergence signals

The bot uses a **weighted voting system** where each model casts votes based on configurable parameters. Only when a sufficient consensus is reached (minimum votes threshold) does the bot execute a trade. This consensus-based approach significantly reduces false signals and improves win rate consistency.

### Key Features

- **Risk Management**: Fixed fractional position sizing based on account equity and predefined risk percentage
- **Dynamic Stop Loss**: ATR-based adaptive stops that adjust to market volatility
- **Take Profit Scaling**: Break-even protection and trailing stops to lock in profits
- **Session Filters**: Trades restricted to optimized market hours (morning/afternoon sessions)
- **Spread Control**: Spreads must remain below configurable thresholds to prevent slippage losses
- **Trend Confirmation**: EMA filters ensure alignment with the predominant trend direction

## Code Structure (`src/StatisticalEdge.mq5`)

The Expert Advisor is organized into several key components:

### Configuration Parameters
- **Risk Management**: Position sizing and risk/reward ratio settings
- **Model Weights**: Individual control for each technical analysis model
- **Indicator Inputs**: Customizable periods and thresholds for all indicators
- **Trading Hours**: Session-based restrictions with morning/afternoon windows
- **Stop Loss/Take Profit**: Dynamic levels calculated using volatility and price action

### Core Functionality
- **Multi-indicator Processing**: Collects signals from Bollinger Bands, RSI, EMA, ATR, and Stochastic Oscillator
- **Voting Algorithm**: Aggregates weighted votes from each model to generate final trading decisions
- **Position Management**: Automates entry, exit, and profit-protection mechanics
- **Divergence Detection**: Identifies hidden divergences in stochastic signals for enhanced accuracy
- **Dynamic Calculations**: All stop loss and take profit levels adjust based on real-time ATR values

### Architecture Highlights
- Built with **CTrade library** for efficient order execution
- Implements **mathematical normalization** for precise price handling
- Stores historical data for divergence analysis and pattern recognition
- Utilizes **time-based filters** to optimize trading during high-liquidity periods

## Installation & Usage

1. Copy `StatisticalEdge.mq5` to your MetaTrader 5 Experts folder
2. Compile the Expert Advisor in the MQL5 editor
3. Attach to a chart and configure parameters based on your trading style
4. Backtest extensively before live trading

## License

See LICENSE file for details.
