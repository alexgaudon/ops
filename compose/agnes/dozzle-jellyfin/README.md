# Dozzle for Agnes and Apophis

The UI stays on Agnes. The existing internal Caddy route still serves
<https://dozzle.internal.misery.systems/>. With the multihost overlay, the UI
lists Agnes's local containers and connects to an Apophis agent for its
containers and logs. Shell and container actions are off on both ends.

## Live deployment

- Agnes: the local `.env` selects `compose.yaml:data/compose.multihost.yaml`.
  The overlay, firewall file, and startup script are installed under the stack's
  ignored `data/` directory. TrueNAS Post Init task 2 runs `dozzle-hub-start.sh`,
  which loads the port filter before starting Dozzle. If Docker alone is
  restarted, rerun that script to start Dozzle. Dozzle stores login and UI
  settings separately from the agent TLS files, in `data/ui/`.
- Apophis: the standalone agent is installed in `/opt/dozzle-agent`.
  `dozzle-agent-filter.service` loads its port filter before Docker at boot.
- Both stacks use private TLS files under their respective `data/agent-tls/`
  directories. Caddy and DNS are unchanged.

## Reinstall

1. Use the included nftables files to restrict TCP `7007` to Agnes (`10.0.0.5`)
   and TCP `8099` to the internal Caddy source (`10.0.0.50`). The HTTPS route
   still uses its existing LAN policy. Anyone allowed by that policy can see
   both hosts' logs.
2. Generate a dedicated TLS pair once, on a trusted machine:

   ```sh
   umask 077
   mkdir -p data/agent-tls
   openssl genpkey -algorithm Ed25519 -out data/agent-tls/dozzle_key.pem
   openssl req -new -x509 -key data/agent-tls/dozzle_key.pem \
     -subj /CN=homelab-dozzle-agent -days 730 -out data/agent-tls/dozzle_cert.pem
   ```

   Securely install both files in `data/agent-tls/` relative to each stack
   directory. Keep the private key mode `0600` and out of Git and chat. Both
   ends need the same pair. Rotate it on both hosts before expiry. Dozzle's
   built-in pair is shared across installations and doesn't authenticate the
   other end of the connection.
3. On Apophis, install `compose.agent.yaml` and `dozzle-agent.nft` under
   `/opt/dozzle-agent` and the filter unit under `/etc/systemd/system`. Then run:

   ```sh
   systemctl daemon-reload
   systemctl enable --now dozzle-agent-filter.service
   docker compose -f /opt/dozzle-agent/compose.agent.yaml up -d
   ```

   This file is intentionally outside the automatic Apophis stack updater.
4. On Agnes, copy `compose.multihost.yaml`, `dozzle-hub.nft`, and
   `dozzle-hub-start.sh` into the stack's `data/` directory. Add this line to
   the stack's local `.env` (preserve any existing settings):

   ```dotenv
   COMPOSE_FILE=compose.yaml:data/compose.multihost.yaml
   ```

   Create `data/ui/` with mode `0700`. Pull `amir20/dozzle:v11.5.0`, then run `/bin/sh data/dozzle-hub-start.sh`
   from the Agnes stack directory. Register the absolute script path under
   TrueNAS Init/Shutdown Scripts as a Post Init command (90-second timeout).
5. Open Dozzle and check that `agnes` and `apophis` are both listed. Open a
   container on each host and confirm that logs load and follow. Verify TCP
   `7007` and direct TCP `8099` are unreachable from an unrelated LAN client.

Keep the hub and agent on matching versions. The agent needs the local Docker
socket even with shell and actions disabled. No Docker API port is published.

## Roll back

Disable the Dozzle TrueNAS Post Init task. Remove `COMPOSE_FILE` from the
local Agnes `.env` and run `docker compose up -d` from its stack directory to
restore the single-host UI. On Apophis, run
`docker compose -f /opt/dozzle-agent/compose.agent.yaml down`, then disable
`dozzle-agent-filter.service`. To remove the port restrictions too, delete the
`inet dozzle_hub` table on Agnes and `inet dozzle_agent` table on Apophis.
