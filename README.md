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
| `POSITION_SIZE_USDT` | Notional size per trade | `50` |
| `LEVERAGE` | Leverage | `5` |
| `MIN_CONFIDENCE` | Minimum confidence to trade | `50` |
| `ORDER_COOLDOWN` | Seconds between orders per symbol | `300` |
| `REPLACE_STALE_LIMITS` | Cancel stale entry LIMIT orders | `true` |
| `CLOSE_ON_OPPOSITE` | Close position when opposite OB is touched | `true` |

Logs are written to `logs/bot.log`, `logs/errors.log`, and `logs/trades.log` (the `logs/` folder is created on startup).

## Hosting

The bot should run on a machine that stays online (VPS or dedicated server). If you need hosting, you can rent a VPS at **[REVISION ALPHA](https://revisionalpha.com)**.

## Project layout

```
trade-binance-websocket-order-blocks/
├── main.sh               # Entry script (run this)
├── lib/                  # Shared libraries (Binance, OB state, guards)
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
