# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 4.3.x | Yes |
| 4.2.x | Yes |
| < 4.2 | No |

## Reporting a vulnerability

Please do **not** open a public issue for security problems. Email **89163930@qq.com** with:

- what you can do that you shouldn't be able to,
- the steps or a minimal proof of concept,
- your OS and PowerShell version (`$PSVersionTable`).

You can expect an acknowledgement within a few days. Since this is a single-maintainer project, please allow reasonable time for a fix before any disclosure.

## Threat model

ServerPanel is designed for a **single-user Windows workstation** with the panel bound to loopback. It is not hardened for multi-user hosts, and it must not be exposed to a network interface.

What the design already assumes and enforces:

- **Local-only HTTP.** The listener binds `127.0.0.1`. Every `/api/*` request except `/api/boot` requires an `X-Panel-Token` header; the token is regenerated per launch.
- **No browser-driven command execution.** The frontend sends identifiers (service id, PID) only. Commands are resolved from `config.json`; nothing from the request body is interpolated into a remote shell.
- **Rebinding and CSRF.** The `Host` header must be `127.0.0.1` / `localhost` / `::1` (421 otherwise) and cross-origin requests are rejected via `Origin` (403). The page ships a CSP with `script-src 'self'` and no inline handlers.
- **Kill protection.** A PID must exist in the latest snapshot and must not match `denyKill` (PIDs, users, command patterns) before a kill is issued.
- **No privilege escalation.** Remote privileged operations use `sudo -n`; the panel never prompts for or stores passwords. SSH runs with `BatchMode=yes`.

## Out of scope

- Anyone who can already run code as your Windows user can read `config.json`, `state/`, and the audit log. That is expected.
- Exposure through a reverse proxy, port forward, or `0.0.0.0` bind is unsupported. If you do it, you own the consequences.
- The remote host's own security posture (SSH configuration, sudoers rules, service permissions) is yours to manage.
