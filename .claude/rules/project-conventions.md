# Project Conventions

## Tech Stack
- Language: Bash (#!/bin/bash, set -e)
- Target platforms: Raspberry Pi OS (Debian/Ubuntu) via `modern-setup/`, Alpine Linux via `modern-setup-alpine/`
- Init systems: systemd (Debian), OpenRC (Alpine)
- Proxy: 3proxy 0.9.4 (compiled from source)
- Network: udev rules + iproute2 routing tables + NetworkManager/systemd-networkd/dhcpcd
- Hardware: Huawei E3372 USB modems (up to 20)

## Architecture
- Style: sequential installer scripts, numbered `01-*` through `05-*`
- Flow: `install.sh` → runs numbered scripts in order → each script is idempotent
- Event handling: udev rules trigger `modem-interface-handler.sh` on interface add/remove
- Boot sync: `modem-sync.sh` runs as systemd oneshot service to re-configure all active modems

## Structure
```
modern-setup/                    # Debian/Ubuntu variant
  install.sh                     # Main installer (orchestrator)
  scripts/
    01-set-limits.sh             # System limits (ulimits, sysctl, systemd)
    02-install-3proxy.sh         # Build & install 3proxy + systemd service
    03-configure-network.sh      # Routing tables + network backend config
    04-setup-udev-rules.sh       # udev rules + helper script deployment
    05-install-sync-service.sh   # modem-sync systemd service
  helpers/
    modem-interface-handler.sh   # udev event handler (routing + 3proxy config)
    modem-sync.sh                # Boot-time interface synchronization
  templates/
    modem-sync.service           # systemd unit file

modern-setup-alpine/             # Alpine Linux variant (OpenRC instead of systemd)
  install.sh
  scripts/
    01-set-limits.sh
    02-install-3proxy.sh         # Uses OpenRC init script instead of systemd
    03-configure-network.sh
    04-setup-udev-rules.sh
  helpers/
    modem-interface-handler.sh
```

## Naming
- Files: kebab-case with numeric prefix for ordering (`01-set-limits.sh`)
- Functions: snake_case (`log_info`, `check_root`, `configure_routing_tables`)
- Variables: UPPER_SNAKE for constants/globals (`PROXY_VERSION`, `MAX_MODEMS`), lower_snake for locals
- Logs: `[SCRIPT_NAME]` prefix with color-coded log levels

## Patterns (confirmed from code)

### Script structure
- Every script starts with `#!/bin/bash`, `set -e`, `SCRIPT_NAME=`
- Every script has `check_root()` guard
- Color-coded logging functions: `log_info` (green), `log_warn` (yellow), `log_error` (red)
- Comments in Russian, user-facing output in Russian
- `main()` function at bottom, called with `main "$@"`

### Idempotency
- All scripts check before modifying (grep before append, file existence before create)
- Backups created with timestamp suffix before overwriting: `*.backup.$(date +%s)`

### State management
- Runtime state in `/var/run/modem-state/` (per-interface IP, subnet, gateway, ports)
- Logs in `/var/log/modem-handler.log` and `/var/log/3proxy/3proxy.log`
- Config in `/etc/3proxy/3proxy.cfg`

### Port mapping
- HTTP proxy: ports 8002-8020 mapped to subnets 192.168.2.x-192.168.20.x
- SOCKS proxy: ports 9002-9020 mapped to same subnets
- Default modem IP: 192.168.X.100

## Testing
- No test framework — scripts are tested on real hardware
- Idempotency is the safety net (re-run to fix)

## Do NOT Use
- No Python, Node, or other runtimes — pure Bash
- No package manager for 3proxy — always compile from source
- No interactive prompts in helper scripts (only in install.sh)
- No modification of eth0 — always exclude from modem rules (critical for SSH access)
