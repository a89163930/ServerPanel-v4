# Changelog

Versions follow `MAJOR.MINOR`. This project was developed privately up to 4.2; the history below starts at the first public release.

## 4.3 — 2026-11-22

Post-release hardening over five internal rounds (R-83…R-89).

**Reliability**

- **Idle semantics change (R-85).** The default is now "stay alive while collecting": the hub exits only after *all* collection has stopped for the configured idle window; with no config it stays resident. `-IdleSec`, an explicit `idleExitSec`, or `SP_IDLE=-1` via the launcher still work as before.
- **Dual-launch guard (R-84).** A kernel mutex (`Global\ServerPanelV4-<port>`) rejects concurrent launches before any agent starts; a crashed predecessor's abandoned lock is taken over automatically — no doubled SSH sessions, no doubled state writes.
- **Sleep/resume handling (R-83).** A wall-clock gap (sleep/hibernate wake) resets the idle timer instead of being judged as idle; every exit leaves a reason line in the log.
- **Cross-generation orphan cleanup (R-88).** Before relaunching an agent, same-host orphan agents from a previous hub generation are killed first, so samples and SSH sessions never double up after a restart.

**Launcher & windows**

- **Blank Edge window fix (R-86).** A dirty dedicated profile made `--app` start a whole stack without creating the initial window; retries now rebuild the profile, and window identity is matched by title only.
- **Double-click hardening (R-87/R-89).** Windows open with extensions disabled and success requires a real titled panel window. If you close the app window while collection continues, the next launch reopens one window instead of exiting silently — always exactly one visible panel window.
- **Warm profile reuse (R-89a).** The dedicated Edge profile is reused by default (fast start) and only rebuilt when an open attempt fails.

**Diagnostics**

- Per-instance transcripts (`log\panel-run.<pid>.log`) so concurrent launches never interleave writes; lifecycle markers still go to `log\panel-run.log`.

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

- `build/gate.ps1` runs all thirteen gates in one pass and distinguishes `FAIL` from `BLOCKED` (missing dependency, exit code 2) so partial verification can't masquerade as success.

**Post-release hardening & features (same 4.2 line)**

- **Launcher fix + regression gate (DR-79/R-82 series).** The shipped BAT died at cmd parse time because an echo line inside an `if (...)` block contained parentheses — every "double-click does nothing" case since then traces back to parse-time death, with no side effects to observe. `test-launcher.ps1` now executes a verbatim copy of the BAT and asserts rc=0; the gate suite count went from twelve to thirteen.
- **Per-process GPU column (schema sp1 → sp2).** `collector.sh` merges nvidia-smi compute-app memory into `procs[].gpuMemMiB`; the process table shows each process's VRAM share (e.g. `354M (1.4%)`). Per-process SM utilization is not exposed by NVIDIA's CLI, and the header states this.
- **Gate assumptions hardened.** The hosts suite no longer hardcodes a host count (a user deleting their own host used to read as FAIL) and its active-host migration test is self-contained; the conns truth-table and archive canary grew to the current schemas.
