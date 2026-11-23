# ServerPanel

Windows-hosted monitoring panel for Linux GPU servers.

Persistent SSH streams pull metrics from each remote host; the web UI reads local
cache files only (zero SSH on request threads), and every control action runs as
an isolated asynchronous child process against a command whitelist.

**Version 4.3** · 2026-11-22 · Release history: [CHANGELOG.md](CHANGELOG.md)
· Security policy: [SECURITY.md](SECURITY.md)

## Features

- **Live monitoring** — CPU (total + per-core load), memory, swap, per-mount disk,
  network rate, top processes, systemd units and pattern-matched services, all
  sampled from a resident SSH stream (`bash + jq + coreutils + procps + iproute2`
  required on the remote host; `nvidia-smi` optional).
- **GPU metrics** — per-card VRAM, temperature, utilization and power; per-process
  VRAM share merged into the process table (`354M (1.4%)`). Multi-GPU supported
  (primary-card aggregation + per-card detail).
- **Alerts** — rule DSL (`metric op threshold forSec cooldownSec`, levels
  `warn` / `bad`, `{value}` templating) plus dead-rule detection that surfaces
  rules which can never fire.
- **Remote control** — start/stop/kill resolved strictly from the config
  whitelist; the frontend sends identifiers only. Kill protection via
  `denyKill` (PIDs, users, command patterns) and `sudo -n` for privileged ops.
- **History & charts** — three-tier history (recent / slim / archive) rendered
  with uPlot dual-axis charts inside the page.
- **Multi-host management** — add / edit / enable-disable / delete hosts from the
  UI, including an SSH connectivity test (hard 18s timeout). Each host gets its
  own agent and state files; no config-file editing or restarts needed.
- **Audit trail** — every action records identity, timestamp, result code and
  output excerpt; the remote probe script is always base64-transported.

## Quick start

Requirements: Windows + PowerShell 7, passwordless SSH configured for each host.

```text
double-click ServerPanel.bat        # hidden backend + app-mode Edge window
pwsh -NoProfile -File panel.ps1     # command line
```

| Flag | Effect |
|---|---|
| `-NoBrowser` | Backend only, no window (automation / always-on use) |
| `-IdleSec <n>` | Override idle-exit seconds; `-1` = resident, never exit |
| `-TestOnce` | Collect one round, then exit (self-check) |

Re-launching while a panel is already running detects the existing instance,
brings its window to the foreground, and this instance exits cleanly. Exactly
one visible panel window exists after every launch.

## Security model

- The HTTP listener binds loopback only (`http://127.0.0.1:48732` by default).
- Every `/api/*` endpoint except `/api/boot` requires an `X-Panel-Token` header;
  the token is regenerated per launch.
- Host-header whitelist (421), Origin check (403), CSP `script-src 'self'`,
  no inline handlers.
- Remote commands come from the config whitelist only; nothing from the request
  body is interpolated into a remote shell. See [SECURITY.md](SECURITY.md) for
  the full threat model.

## Architecture

```text
panel.ps1 (hub, HTTP)
  reads state/*.json cache        <- written by agent.ps1 (one per host)
                                     persistent SSH stream -> collector.sh
                                     (uploaded once per stream)
actions go out through action.ps1 (one child process per action),
results land in state/actions/<id>.json
```

The remote collector is uploaded once when a stream starts and leaves nothing on
the remote disk; the currently effective collector version is shown in the UI as
`Collector <sha256-prefix>` under Alerts & Audit → Collector Health, matching the
first 12 hex characters of `collector.sh`.

## Configuration

Copy `config.example.json` to `config.json` and adjust:

| Field | Purpose |
|---|---|
| `port` | Panel port (default 48732) |
| `activeHost` | Which host the panel tracks on launch |
| `sshOpts` | Extra ssh options (e.g. timeouts / keepalives) |
| `idleExitSec` | Optional: seconds of pure idleness after all collection stops before exiting; omitted = stay resident while any collection is alive |
| `hosts[]` | Per-host settings: `id`, `label`, `sub`, `sshHost` (SSH alias), `intervalSec`, `historyEverySamples`, `enabled`, `services[]` |
| `services[]` | Controlled entries: `id`, `kind` (`systemd` \| `pattern`), `unit`/`pattern`, `startCmd`/`stopCmd`/`logCmd`, guard rails (`warnIfActive`, `allowEnable`, `confirmStop`) |
| `denyKill` | Kill-protection list: `pids[]`, `userMatch[]`, `cmdMatch[]` |
| `alerts[]` | Alert rules: `metric`, `op`, `threshold`, `forSec`, `cooldownSec`, `level`, `text` |
| `history` | `keepDays`, `maxFileMB` |

Adding a host from the UI needs no config edit and no restart: top-right →
Host management → enter display name and SSH target → Test connection → Add.
Host identifiers pass a strict whitelist regex so they can never be spliced into
ssh options; each config write is backed up first (`config.json.bak`), deletions
keep `history/` archives, and orphaned state files are cleaned on next start.

## Tests

Run the master gate in one pass:

```powershell
pwsh -File build/gate.ps1          # exit 0 = all pass, 1 = failure, 2 = not executed (not a pass)
pwsh -File build/gate.ps1 -Only hosts   # single suite
```

Thirteen gates cover end-to-end acceptance, host management regression,
collector contracts, injection barriers, the launcher contract (a verbatim BAT
copy must execute rc=0 — guards against parse-time death on double-click),
loopback truth tables, chart pixel checks, syntax checking and audit hygiene.

> Scripts and tests **must run under pwsh 7**. Windows PowerShell 5.1 parses
> BOM-less UTF-8 scripts as local GBK and mangles Chinese strings; that was the
> historical root cause of garbled host names, not a panel-code bug.

## Documentation

- Presentation-layer design baseline: [`docs/design-review-v4.1.md`](docs/design-review-v4.1.md)
- Release history: [`CHANGELOG.md`](CHANGELOG.md)
- Security policy: [`SECURITY.md`](SECURITY.md)

## Known limitations

- Closing the panel window lets collection stop with it (resident mode +
  boot-time scheduled task gives 7×24 operation; the launcher also honours the
  system variable `SP_IDLE=-1`).
- Sleeping/resuming wakes get a grace period: wall-clock drift on wake no longer
  triggers a false idle exit; resume events and exit reasons are logged.
- The panel manages remote Linux hosts only; local Windows services are out of
  scope. Port ownership needs root on the remote host.
- A service entry whose remote path no longer exists fails honestly when started
  (reported in the audit trail rather than silently swallowed).
- Browser timer throttling (minimized window / background tab) only affects the
  visible "synced" timestamp, not collection — judge freshness by `ageSec` in
  `state/meta-<id>.json`.

This project is developed and maintained by a single maintainer. Bug reports and
security disclosures: see SECURITY.md.