---
title: NPM traffic audit
description: >
  Managed by Kimaki routines. Do not move or delete this file while either
  scheduled audit is pending.
---

Report legacy Nginx Proxy Manager traffic since 2026-11-20 01:14 UTC, plus
daily counts so the day-five run can show the change since day three. Focus
on `amgau.xyz`, `homepage.amgau.xyz`, `jellyfin.amgau.xyz`, the `bootkept-…`
Tibiactl host, Relay, Tallyo, OneCLI, code-server, Jellystats, and the three
connector URLs. Note any other consistently active old routes. Report counts
and successful response days, distinguish known probes where possible, and
describe gaps in log coverage. Don't equate request counts with users or zero
observed requests with proof that a route is unused.

Keep this audit read-only: no proxy/DNS changes, service restarts, or test
requests to the old routes. Never print raw logs, client IPs, paths, query
strings, or secrets. Use aggregate statistics only. The NPM API can map rule
IDs to hostnames; the old dev-proxy checkout has the existing credentials.

SSH to Proxmox host `sorrow` works; direct SSH to NPM VM 600 did not. The
previous audit successfully read current and rotated `/root/npm/logs/proxy-host-*_access.log*`
from the VM disk via a temporary strictly read-only loop view and `debugfs -c`,
then detached it. Verify the disk and partition layout first; don't mount,
repair, or write to the guest filesystem. See the parent Discord thread for
the earlier audit and its commands. If access fails, report the gap rather
than guessing. Prioritize the named routes if processing all logs is too slow.

Post the findings or blocker in the reporting thread. Mention Discord user
489123999889227776 only if the results need review or a decision. Do not
disable routes or schedule more jobs.
