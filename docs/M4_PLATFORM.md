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
| LAN hostnames | Hosts-file entries on the PC pointing at the Gateway IP (HomeLab `k8s_client`), until Pi-hole (backlog) |
| LoadBalancer IPs | Cilium LB-IPAM, one small pool on the site LAN outside the router's DHCP pool, announced with Cilium L2 announcements (ARP) |
| Where L2 answers | Only nodes labelled `homelab/l7-proxy=supported` (laptop-01, rpi-03). The Gateway's traffic goes through Envoy, which can't run on the Pi 4s |
| Gateway | Cilium Gateway API (v1.6.1 CRDs, standard channel), one shared `Gateway` in `gateway`, HTTPS listener with the wildcard cert, HTTP → HTTPS redirect |
| Storage | `local-nvme` StorageClass (no provisioner, `WaitForFirstConsumer`, `Retain`). PVs are created per workload in M6, on rpi-03's `/mnt/nvme/k8s/<name>` |
| Public access | cloudflared Deployment (2 replicas, arm64), locally-managed tunnel: ingress rules in git, credentials as a SOPS secret. The tunnel forwards to the Gateway inside the cluster |
| Backups | External drive on a Pi at the site, served over NFS. etcd snapshots copied there daily (still also fetched home) |
| Cilium values | Flux owns them. HomeLab's install seed keeps only the core networking values. Gateway API and L2 announcements are Flux-only, so a rebuild comes up with a plain CNI and Flux finishes it |

## PRs

| # | Repo | PR | Needs | Status |
|---|---|---|---|---|
| 1 | homelab-cluster | **cert-manager** controller (HelmRelease v1.21.2, CRDs managed by the chart) | — | Open |
| 2 | homelab-cluster | **Gateway API + L2 announcements**: Gateway API v1.6.1 CRDs; Cilium `gatewayAPI.enabled`, `l2announcements.enabled`, `externalIPs.enabled`, a higher API client rate limit. Restarts the Cilium agents once | — | Open |
| 3 | homelab-cluster | **`infrastructure-configs` Kustomization + `local-nvme` StorageClass** | — | Open |
| 4 | homelab-cluster | **LB-IPAM pool + L2 announcement policy** (`infrastructure/configs/cilium/`) | The site router's DHCP pool, to confirm the range | Draft |
| 5 | homelab-cluster | **ClusterIssuers** (`letsencrypt-staging`, `letsencrypt`) with the Cloudflare token as a SOPS secret | Cloudflare API token, scoped to Zone:DNS:Edit on `green-tech-hub.com` | To do |
| 6 | homelab-cluster | **Gateway**: namespace, wildcard `Certificate`, `Gateway` with HTTPS + redirect, test app `whoami` with an `HTTPRoute` | 2, 4, 5 | To do |
| 7 | HomeLab | **PC hosts entries** for `*.home.green-tech-hub.com` names → Gateway IP (`k8s_client`) | 6 (the IP) | To do |
| 8 | homelab-cluster | **cloudflared**: Deployment, config with ingress rules, SOPS tunnel credentials; public `whoami.green-tech-hub.com` | Tunnel created (`cloudflared tunnel create homelab`), DNS CNAME | To do |
| 9 | HomeLab | **Backup target**: role for the external drive (mount by UUID, NFS export to the site LAN), `etcd_backup` copies snapshots there | Drive attached to a Pi | Waiting for hardware |
| 10 | both | **Docs + M4 exit**: runbook for adding a service behind the Gateway; M4 marked done | 1–9 | To do |

Order: 1, 2 and 3 can merge in any order. Then 4 once the range is confirmed, and 5 once the token exists. Then 6
→ 7 → 8. 9 is independent.

## What's needed from you

1. **The site router's DHCP pool.** PR 4 proposes `192.168.50.240–192.168.50.250`. Confirm it's outside the
   pool and unused.
2. **A Cloudflare API token:**
   - Permissions: Zone → DNS → Edit, plus Zone → Zone → Read.
   - Zone resources: only `green-tech-hub.com`.
   - Encrypt it into the SOPS secret yourself (PR 5 has the command). It never goes in chat or plain text.
3. **A tunnel:** `cloudflared tunnel login` and `cloudflared tunnel create homelab` on the PC. The credentials
   JSON gets encrypted the same way.
4. **A drive for backups**, attached to rpi-01 or rpi-02.

## Things to watch

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
