# Changelog

Versions follow `MAJOR.MINOR`. This project was developed privately up to 4.2; the history below starts at the first public release.

## 4.2 — 2026-11-20

First public release.

**Monitoring**

- Live CPU (total + per-core load), memory, swap, per-mount disk, network rate, top processes, systemd unit and pattern-matched process state.
- GPU metrics from `nvidia-smi`: per-card VRAM, temperature, utilization, power; primary-card aggregation for charts.
- Three-tier history (recent / slim / archive) with adjustable time window, stored as JSON and rendered with uPlot dual-axis charts.

**Alerts**

- Rule DSL: `metric + op + threshold + forSec + cooldown`, levels `warn` / `bad`, `{value}` templating.
- Metric surface includes `cpu.pct`, `cpu.loadPerCore`, `mem.pct`, `swap.pct`, `disk.maxPct`, `gpu.util`, `gpu.tempC`, `gpu.memPct`, `net.rxKBs`, `net.txKBs`, `agent.ageSec`, `service.<unit>`.
- **Dead-rule detection (DR-78)**: rules that can never fire — a typo'd metric name, or a threshold outside the value's range — are reported in the UI instead of silently never alerting.

**Actions**

- Service start/stop (systemd) and process start/stop/kill (pattern), all resolved from the config whitelist; the frontend sends identifiers only.
- `denyKill` protects PIDs, users, and command patterns; privileged operations use `sudo -n`.
- Every action is written to the audit log with identity, timestamp, result code, and output excerpt.

**Host management**

- Add, edit, enable/disable, and delete hosts from the UI, including an SSH connectivity test with a hard timeout; no config edit or restart required.
- Invalid identifiers are rejected by whitelist regex, config writes are backed up before replacement, and a broken edit can be rolled back.

**Remote collector**

- `collector.sh` requires only `bash + jq + coreutils + procps + iproute2`; it is piped over SSH when a stream starts and leaves nothing on the remote disk.
- Any failed probe yields `null` plus an `errors[]` entry — values are never fabricated as `0`.
- The active collector version is surfaced in the UI as `Collector <sha256-prefix>`.

**Tests**

- `build/gate.ps1` runs all twelve gates in one pass and distinguishes `FAIL` from `BLOCKED` (missing dependency, exit code 2) so partial verification can't masquerade as success.
