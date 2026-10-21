# M4: Platform

The platform layer that M6 workloads land on: LoadBalancer IPs, a Gateway with TLS, local storage, public access
through Cloudflare, and a backup target. This is the working plan. Each item is one PR, and its status is updated
here as it lands.

**Exit test:**
- A test app is reachable by hostname on the LAN over HTTPS, and publicly through the tunnel.
- An etcd snapshot lands on the backup target.

## Decisions

| Topic | Decision |
|---|---|
| Domain | `green-tech-hub.com`, DNS on Cloudflare. LAN services under `*.home.green-tech-hub.com`; public services as `<name>.green-tech-hub.com` through the tunnel |
| LAN certificates | Let's Encrypt via cert-manager, DNS-01 against Cloudflare. One wildcard `*.home.green-tech-hub.com` certificate on the Gateway. No inbound ports |
| LAN hostnames | One public Cloudflare record, `*.home.green-tech-hub.com` A `192.168.50.240`, DNS only (21 Oct 2026). Every device that can reach the site LAN resolves every service with no hosts files, and a new service needs no DNS change. The cost is that a private IP is visible in public DNS. Replaces the earlier hosts-file plan (Windows needs elevated edits; WSL's `/etc/hosts` is separate). Pi-hole split horizon stays in the backlog |
| LoadBalancer IPs | Cilium LB-IPAM, pool `192.168.50.240–.250` on the site LAN, announced with Cilium L2 announcements (ARP). The router's DHCP pool was shrunk to `.30–.239` (21 Oct 2026) to make room; node static IPs sit below `.30` |
| Where L2 answers | Only nodes labelled `homelab/l7-proxy=supported` (laptop-01, rpi-03). The Gateway's traffic goes through Envoy, which can't run on the Pi 4s |
| Gateway | Cilium Gateway API (v1.6.1 CRDs, standard channel, imported by commit, not vendored), one shared `Gateway` (`gateway/homelab`, pinned to `192.168.50.240`), HTTPS listener with the wildcard cert, HTTP → HTTPS redirect. Each service adds an `HTTPRoute` with parentRef `gateway/homelab`, sectionName `https` |
| Storage | `local-nvme` StorageClass (no provisioner, `WaitForFirstConsumer`, `Retain`). PVs are created per workload in M6, on rpi-03's `/mnt/nvme/k8s/<name>` |
| Public access | cloudflared Deployment (2 replicas, arm64), locally-managed tunnel: ingress rules in git, credentials as a SOPS secret. The tunnel forwards to the Gateway inside the cluster |
| Backups | External drive on a Pi at the site, served over NFS. etcd snapshots copied there daily (still also fetched home) |
| Cilium values | Flux owns them. HomeLab's install seed keeps only the core networking values. Gateway API and L2 announcements are Flux-only, so a rebuild comes up with a plain CNI and Flux finishes it |

## PRs

| # | Repo | PR | Needs | Status |
|---|---|---|---|---|
| 1 | homelab-cluster | **cert-manager** controller (HelmRelease v1.21.2, CRDs managed by the chart) | — | [#6](https://github.com/GreenMachine582/homelab-cluster/pull/6) |
| 2 | homelab-cluster | **Gateway API + L2 announcements**: Gateway API v1.6.1 CRDs imported from upstream (GitRepository pinned by commit, applied by a service account limited to CRDs and admission policies); Cilium `gatewayAPI.enabled`, `l2announcements.enabled`, `externalIPs.enabled`, a higher API client rate limit. Restarts the Cilium agents once | — | [#12](https://github.com/GreenMachine582/homelab-cluster/pull/12) |
| 3 | homelab-cluster | **`infrastructure-configs` Kustomization + `local-nvme` StorageClass** | — | [#8](https://github.com/GreenMachine582/homelab-cluster/pull/8) |
| 4 | homelab-cluster | **LB-IPAM pool + L2 announcement policy** (`infrastructure/configs/cilium/`) | 2, 3; DHCP pool shrunk to `.30–.239` (done) | [#9](https://github.com/GreenMachine582/homelab-cluster/pull/9) |
| 5 | homelab-cluster | **ClusterIssuers** (`letsencrypt-staging`, `letsencrypt`) with the Cloudflare token as a SOPS secret | Cloudflare API token, scoped to Zone:DNS:Edit on `green-tech-hub.com` (done) | [#14](https://github.com/GreenMachine582/homelab-cluster/pull/14) |
| 6 | homelab-cluster | **Gateway**: namespace, wildcard `Certificate`, `Gateway` with HTTPS + redirect, test app `whoami` with an `HTTPRoute`. Proved on `letsencrypt-staging`, then switched to `letsencrypt` | 2, 4, 5 | [#15](https://github.com/GreenMachine582/homelab-cluster/pull/15), [#16](https://github.com/GreenMachine582/homelab-cluster/pull/16) |
| 7 | both | **LAN names**: the `*.home` A record in Cloudflare (manual, see [Cloudflare setup](#cloudflare-setup-manual)); HomeLab `cluster_status.yml` checks resolution and HTTPS from the controller | 6 (the IP) | [#17](https://github.com/GreenMachine582/homelab-cluster/pull/17), HomeLab [#9](https://github.com/GreenMachine582/HomeLab/pull/9), [#10](https://github.com/GreenMachine582/HomeLab/pull/10) |
| 8 | both | **cloudflared**: Deployment, config with ingress rules, SOPS tunnel credentials; public `whoami.green-tech-hub.com`. HomeLab installs the pinned CLI on the controller | Tunnel created (`cloudflared tunnel create homelab`), DNS CNAME | HomeLab [#11](https://github.com/GreenMachine582/HomeLab/pull/11); cluster side in progress |
| 9 | HomeLab | **Backup target**: role for the external drive (mount by UUID, NFS export to the site LAN), `etcd_backup` copies snapshots there | Drive attached to a Pi | Waiting for hardware |
| — | homelab-cluster | **Block remote kustomize bases** (`--no-remote-bases=true`): external content only through pinned Flux sources | — | [#10](https://github.com/GreenMachine582/homelab-cluster/pull/10) |
| 10 | both | **Docs + M4 exit**: runbook for adding a service behind the Gateway; M4 marked done | 1–9 | To do |

Order: 1, 2 and 3 can merge in any order. Then 4, and 5 once the token exists. Then 6 → 7 → 8. 9 is independent.
Steps done by hand in Cloudflare are listed under [Cloudflare setup](#cloudflare-setup-manual).

## What's needed from you

1. **A Cloudflare API token** (done, 21 Oct 2026):
   - Permissions: Zone → DNS → Edit, plus Zone → Zone → Read.
   - Zone resources: only `green-tech-hub.com`.
   - Stored only as `infrastructure/configs/cert-manager/cloudflare-api-token.sops.yaml`. Recreate or rotate it
     with [SECRETS.md](SECRETS.md).
2. **The `*.home` DNS record** (done, 21 Oct 2026). See [Cloudflare setup](#cloudflare-setup-manual).
3. **A tunnel:** `cloudflared tunnel login`, `cloudflared tunnel create homelab` and
   `cloudflared tunnel route dns homelab whoami.green-tech-hub.com` in WSL. The credentials JSON is encrypted as
   in [SECRETS.md](SECRETS.md).
4. **A drive for backups**, attached to rpi-01 or rpi-02.

## Cloudflare setup (manual)

Everything on the Cloudflare side that isn't in git, enough to rebuild it from scratch. Zone: `green-tech-hub.com`.
Update this table whenever the dashboard changes.

| What | Where in the dashboard | Value | Used by |
|---|---|---|---|
| API token | My Profile → API Tokens | Custom token: Zone · DNS · Edit and Zone · Zone · Read, zone `green-tech-hub.com` only. Recreate: [SECRETS.md](SECRETS.md) | cert-manager DNS-01 (#14) |
| LAN wildcard record | green-tech-hub.com → DNS → Records | Type `A`, name `*.home`, IPv4 `192.168.50.240` (the Gateway, `infrastructure/configs/gateway/gateway.yaml`), **DNS only** (grey cloud), TTL Auto | Every `*.home.green-tech-hub.com` service |
| Apex record + tunnel route | DNS → Records; Zero Trust → Networks → Tunnels | Pre-existing, proxied apex `green-tech-hub.com` routed through a tunnel to `https://localhost:8080`. Not managed by this repo | Outside the cluster |
| `homelab` tunnel | Zero Trust → Networks → Tunnels | Locally managed (the dashboard shows it but its ingress rules live in `infrastructure/configs/cloudflared/configmap.yaml`). ID `0906ae8b-a6d6-49d7-80f4-6bc4d724fcca`. Created in WSL with `cloudflared tunnel login` (writes `~/.cloudflared/cert.pem`, pick `green-tech-hub.com`) then `cloudflared tunnel create homelab`. Credentials: [SECRETS.md](SECRETS.md) | cloudflared |
| Public `whoami` record | DNS → Records | `CNAME` `whoami` → `0906ae8b-a6d6-49d7-80f4-6bc4d724fcca.cfargotunnel.com`, **proxied**. Created with `cloudflared tunnel route dns homelab whoami.green-tech-hub.com` | Public whoami (M4 exit test) |

Notes:
- The A record must stay **DNS only**. Proxied, Cloudflare would answer with its own IPs and couldn't reach a
  private address anyway.
- If the Gateway IP changes (`gateway.yaml` `spec.addresses`), change the record too.
- Certificate renewals are unaffected: DNS-01 writes TXT records at `_acme-challenge.home`, which the wildcard A
  doesn't shadow.
- Check it: `nslookup whoami.home.green-tech-hub.com 1.1.1.1` and the same against the local resolver should
  both give `192.168.50.240`. If only the local resolver returns nothing, it's dropping private-IP answers
  (DNS-rebind protection). The home ASUS router doesn't (checked 21 Oct 2026).

**Publishing a service** (it already has an HTTPRoute for `<name>.home.green-tech-hub.com`):
1. Add an ingress rule to `infrastructure/configs/cloudflared/configmap.yaml`, above the 404 catch-all. Copy the
   whoami rule and change both `<name>` values. Bump `homelab/config-rev` in `deployment.yaml` so the pods restart.
2. `cloudflared tunnel route dns homelab <name>.green-tech-hub.com` in WSL, and add the record to the table above.
3. Removing one: delete the rule, then delete its CNAME in the dashboard.

## Things to watch

- **Public whoami:** it echoes request headers and internal IPs to anyone. It's there for the M4 exit test; remove
  its tunnel rule and CNAME (or put it behind Cloudflare Access) once M4 is done.
- **cloudflared placement:** it must run on an Envoy node to reach the Gateway, so its one replica sits on rpi-03.
  If rpi-03 is down, public access is down.
- **cloudflared protocol:** the site network drops outbound UDP 7844, so QUIC fails. The tunnel is pinned to
  `protocol: http2` over TCP 7844, which cloudflared's own pre-check also recommends. If the site firewall ever
  allows UDP 7844, the pin can go.

- **Agent restart:** PR 2 changes `cilium-config`, so with `rollOutCiliumPods` every agent restarts once, a
  few seconds of pod-network interruption per node. Merge it when nothing important is running (true until M6).
- **ARP for the pool:** L2 announcements answer ARP for pool IPs from one supported node at a time (a lease). If
  that node goes down, another supported node takes over within the lease duration (~15 s). With only laptop-01
  and rpi-03 eligible, both being down means the Gateway is unreachable.
- **DR:** after a rebuild, Ansible installs Cilium without Gateway/L2. Flux then applies the CRDs and upgrades
  Cilium with them. If the Gateway stays `Programmed: False`, restart `deploy/cilium-operator` once. It only checks
  for the Gateway API CRDs at start.
- **DNS-01:** cert-manager checks propagation against public resolvers (`1.1.1.1`, `8.8.8.8`), not the site
  router, so a router DNS quirk can't stall issuance.
