# trade-binance-websocket-order-blocks

**trade-binance-websocket-order-blocks** is a **Binance Futures** trading bot that streams the **order book** over WebSocket, detects support/resistance zones (order blocks), and places LIMIT orders with TP/SL via REST or Finandy.

## Requirements

- macOS or Linux with **bash 3.2+**
- [jq](https://stedolan.github.io/jq/): `brew install jq`
- [websocat](https://github.com/vi/websocat): `brew install websocat`
- `bc`, `curl`, `openssl`
- **Binance Futures** API keys (for `rest` mode)

## Installation

```bash
git clone <your-repo> trade-binance-websocket-order-blocks
cd trade-binance-websocket-order-blocks
cp .env.example .env
# Edit .env with your keys (`.env` is gitignored; see `.env.example` for all defaults)
chmod +x main.sh
```

## Usage

The **only entry script** in this project is `main.sh` (project root). All logic lives there and in `lib/`.

```bash
# All symbols from SYMBOLS (.env)
./main.sh

# Single pair
./main.sh BCHUSDT

# Simulation (no real orders)
./main.sh --dry-run
./main.sh -d ETHUSDT
```

### Main variables (`.env`)

| Variable | Description | Default |
|----------|-------------|---------|
| `SYMBOLS` | Comma-separated pairs | `BTCUSDT,ETHUSDT,SOLUSDT` |
| `DEPTH` | Order book depth (5, 10, 20) | `10` |
| `WS_SPEED` | Stream update speed | `500ms` |
| `ORDER_EXECUTION_MODE` | `rest` or `finandy` | `rest` |
| `POSITION_SIZE_MODE` | `wallet_pct` or `fixed_usdt` | `wallet_pct` |
| `POSITION_WALLET_PCT` | % of **totalWalletBalance** (USDT futures) per new order | `10` |
| `POSITION_SIZE_USDT` | Fixed notional (fallback or `fixed_usdt` mode) | `50` |
| `LEVERAGE_MODE` | `max` = symbol max leverage, `fixed` = `LEVERAGE` | `max` |
| `LEVERAGE` | Leverage when `LEVERAGE_MODE=fixed` or max API fails | `5` |
| `TP_SL_MODE` | `percent` or `ob_grid` (structural TP/SL from order-book walls) | `percent` |
| `OB_WALL_SHIFT_PCT` | Min % move to promote current wall to R1/S1 | `0.15` |
| `SL_OB_BUFFER_PCT` / `TP_OB_BUFFER_PCT` | Buffer % beyond grid SL/TP levels | `0.05` |
| `OB_GRID_MIN_SL_PCT` | Minimum SL distance from entry in `ob_grid` (defaults to `SL_PERCENT`) | — |
| `OB_GRID_MIN_R0_R1_GAP_PCT` | If R0≈R1, use 2nd wall or range extension | `0.2` |
| `OB_GRID_SL_RANGE_RATIO` | Fraction of (R0−S0) added beyond R0 for SHORT SL | `0.382` |
| `MIN_CONFIDENCE` | Minimum confidence to trade | `50` |
| `ORDER_COOLDOWN` | Seconds between orders per symbol | `300` |
| `TRADING_SCHEDULE_ENABLED` | Enforce days/hours window for **new orders** | `true` |
| `EXECUTION_HOUR_START` / `EXECUTION_HOUR_END` | UTC hours (end **exclusive**, like trade-deepseek) | `0` / `23` |
| `ALLOWED_DAYS` | Comma-separated 1=Mon … 7=Sun | `1,2,3,4,5,6,7` |
| `REPLACE_STALE_LIMITS` | Cancel stale entry LIMIT orders | `true` |
| `CLOSE_ON_OPPOSITE` | Close position when opposite OB is touched | `true` |

In **hedge mode**, the bot blocks a second direction on the same symbol: any open position (LONG or SHORT leg), both entry limits at once, or a new order while the opposite-side limit is still on the book (after `REPLACE_STALE_LIMITS` cancels the old one).

On startup (with API keys), the bot syncs **open positions and pending entry limits** for every symbol in `SYMBOLS`, restores local state (`ACTIVE`, direction, entry, SL/TP from Binance), and logs what it found.

### Trading schedule

Same rules as [trade-deepseek](mdc:../trade-deepseek/deepseek.sh): only **opening** orders are blocked outside the window. Lock profit, SL/TP on open positions, and `CLOSE_ON_OPPOSITE` still run.

Example (Tue–Thu, 14:00–18:59 UTC):

```env
EXECUTION_HOUR_START=14
EXECUTION_HOUR_END=19
ALLOWED_DAYS=2,3,4
```

Set `TRADING_SCHEDULE_ENABLED=false` for 24/7 trading.

### TP/SL modes

- **`percent`** (default): `SL_PERCENT` / `TP_PERCENT` from entry price.
- **`ob_grid`**: tracks order-book walls over time. On each signal, levels are frozen:
  - **SHORT**: SL at **R1** (previous resistance), TP at **S0** (current support), entry near **R0**.
  - **LONG**: SL at **S1** (previous support), TP at **R0** (current resistance), entry near **S0**.
  - If grid geometry is invalid or R1/S1 missing, falls back to `percent` for that order.
| `LOCK_PROFIT_ENABLED` | Tighten SL as price nears TP (`ORDER_EXECUTION_MODE=rest`) | `true` |
| `LOCK_PROFIT_BE_PCT` | % toward TP before SL is moved (trigger) | `70` |
| `LOCK_PROFIT_SL_AT_PCT` | Where to place SL: % of entry→TP distance from entry | `40` |
| `LOCK_PROFIT_BUFFER_PCT` | Fallback buffer if `LOCK_PROFIT_SL_AT_PCT=0` (legacy break-even) | `0.05` |
| `LOCK_PROFIT_STAGE2_PCT` | Optional 2nd stage: lock % of open profit (`0` = off) | `0` |

Example (SHORT): entry `1.00`, TP `0.90` → at **50%** progress toward TP the bot moves SL to **20%** of the range: `1.00 − 0.10×20%` = `0.98` (not full break-even). Needs `REST_PLACE_SL_TP=true` (or an existing STOP on Binance). Logs: `LOCK_PROFIT … stage=lock_sl`.

Logs are written to `logs/bot.log`, `logs/errors.log`, and `logs/trades.log` (the `logs/` folder is created on startup).

## Hosting

The bot should run on a machine that stays online (VPS or dedicated server). If you need hosting, you can rent a VPS at **[REVISION ALPHA](https://revisionalpha.com)**.

## Project layout

```
trade-binance-websocket-order-blocks/
├── main.sh               # Entry script (run this)
├── lib/                  # Shared libraries (Binance, OB state, guards, lock profit)
├── logs/                 # Runtime logs (gitignored)
├── .env.example
└── README.md
```

## License

**trade-binance-websocket-order-blocks** is licensed under **[AGPL-3.0](https://www.gnu.org/licenses/agpl-3.0.html)**.

If you deploy or modify this software (including running the bot on a server), you must comply with AGPL-3.0 (source availability, license notices, and documenting changes) and:

1. Notify the project maintainers: [hola@idoneo.dev](mailto:hola@idoneo.dev)
2. Share modifications or enhancements via the same contact

## Contact

Questions, support, or license-related notices: [hola@idoneo.dev](mailto:hola@idoneo.dev)

## Security

Do not commit `.env` or API keys to the repository. Report security issues to [hola@idoneo.dev](mailto:hola@idoneo.dev).

## Disclaimer

Trading software carries risk of capital loss. Use at your own risk; this is not financial advice.
