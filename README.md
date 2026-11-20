# ServerPanel v4

> Remote Linux GPU server monitoring panel. Zero-install remote agent, native Windows UI.

## Why this exists

Prometheus, Grafana Agent, Zabbix, Netdata—all require installing an agent on the remote host. When you're managing a bare GPU server without root, without package install rights, or even without `systemd`, those solutions either can't be installed or are overkill.

ServerPanel solves this: **zero-install remote**, **native Windows UI**, **GPU-first**, and **actionable** (not just read-only).

- **Zero-install remote** — the remote only needs `bash + jq + coreutils + procps + iproute2` (present on almost every Linux distro). `collector.sh` is uploaded once over SSH when the stream starts; no persistent agent, no disk footprint.
- **Native Windows experience** — PowerShell 7 backend, vanilla HTML/JS + uPlot frontend. Double-click a bat to launch an Edge app-mode window; no browser setup needed.
- **GPU-first** — nvidia-smi parsed natively, single/multi-GPU aggregated automatically. Alerts are designed around GPU memory pressure, temperature, and SM utilization.
- **Actions, not just views** — start/stop services, kill processes. All real commands come from a config whitelist; the frontend only sends IDs. No user-defined scripts executed remotely.

## Quick start

```bash
git clone https://github.com/a89163930/ServerPanel-v4.git
cd ServerPanel-v4
copy config.example.json config.json
# edit config.json: hosts[].sshHost, services, etc.
.\ServerPanel.bat
```

Open `http://127.0.0.1:48732` (or your configured port).

## Windows requirements

- **PowerShell 7** (`pwsh`) — install once with `winget install Microsoft.PowerShell`.
- **OpenSSH client** — bundled with Windows 10/11 (enable via *Settings → Apps → Optional features* if missing).
- **Edge or Chromium** for the app-mode window. The launcher probes for an installed browser and falls back to `http://127.0.0.1:<port>` in the default browser if none is found.

All three are already present on most developer machines.

## Features

| Feature | Details |
|---------|---------|
| **Live metrics** | CPU (total + per-core load), memory, disk, network, GPU VRAM/temperature/SM, top processes (per-process CPU% is normalized per logical core — 100% = one core saturated, matching `top`/`htop`), service state |
| **History** | uPlot dual-axis charts, 3-tier history, adjustable time window |
| **Alerts** | Threshold + duration + cooldown; dead-alert detection (DR-78) |
| **Actions** | Service start/stop, process kill, all via config whitelist |
| **Host mgmt** | Add/edit/delete hosts + SSH test, no restart needed |
| **Audit log** | Every action logged with identity, timestamp, result code |

## Remote requirements

```bash
bash, jq, coreutils, procps, iproute2
# nvidia-smi optional (for GPU metrics)
```

No Python, no Node.js, no persistent daemon.

## Project structure

| File | Role |
|------|------|
| `panel.ps1` | HTTP hub, reads `state/` cache only |
| `agent.ps1` | Per-host SSH streaming session |
| `action.ps1` | Async kill/service toggles |
| `collector.sh` | Remote metrics collector |
| `app.js` | Frontend (vanilla JS + uPlot) |

## Remote collector notes

- `collector.sh` is uploaded **once when a stream starts**. Editing the script requires restarting the agent (or waiting for the session to reconnect) before the change takes effect.
- The active version is shown in the UI as `Collector <sha256-prefix>` and equals the SHA256 prefix of `collector.sh` — use it to confirm your running copy matches the repo.
- Schema is currently **sp2**: `procs[]` carries a per-process `gpuMemMiB` field. NVIDIA does not expose per-process SM utilization via the nvidia-smi CLI (verified on driver 580.x), so per-process GPU usage is reported by VRAM share, e.g. `354M (1.4%)`. Whole-card utilization is still available as usual.

## Tests

```bash
# Master gate (all thirteen suites)
pwsh -File build/gate.ps1
```

Suites include the launcher contract (`build/test-launcher.ps1`: the double-click BAT must be cmd-parseable and exit 0 when run as-is), the hosts-management regression, the collector contracts (schema, error semantics, per-process VRAM canary), loopback/IP truth tables, chart pixel checks, and audit hygiene (test traffic must never evict real user actions from the visible audit window).

> Tests require **PowerShell 7**. Windows PowerShell 5.1 will mangle UTF-8.

## Config

Edit `config.json`:

- `hosts[]`: add your servers (`sshHost`, `intervalSec`, `services[]`)
- `services[]`: systemd units or pattern-matched processes
- `alerts[]`: threshold rules with cooldown
- `denyKill`: protect critical PIDs/users/commands

See `config.example.json` for a full annotated template.

## Known limits

- Window close stops collection (use `-NoBrowser -IdleSec -1` for 24×7)
- Multi-GPU supported (`gpus[]` array)
- Remote Linux hosts only

## License

MIT — see [LICENSE](LICENSE).

## Credits

Thanks to [TokenRhythm](https://tokenrhythm.studio) / [Neohorse](https://tokenrhythm.studio) for the `neohorse-1.5-flash-preview` model, which assisted in parts of this project.
