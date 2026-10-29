# homelab-cluster

![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?logo=kubernetes&logoColor=white)
![Flux](https://img.shields.io/badge/Flux-5468FF?logo=flux&logoColor=white)
![Cilium](https://img.shields.io/badge/Cilium-F8C517?logo=cilium&logoColor=black)
![Cloudflare](https://img.shields.io/badge/Cloudflare-F38020?logo=cloudflare&logoColor=white)
![SOPS + age](https://img.shields.io/badge/secrets-SOPS%20%2B%20age-555555)
![Self-hosted](https://img.shields.io/badge/self--hosted-homelab-4A90D9)
![Status](https://img.shields.io/badge/status-M5_done%2C_M5.5_next-yellow)

GitOps repository for the homelab Kubernetes cluster. Everything running inside the cluster is declared here and
applied by [Flux](https://fluxcd.io). Nothing is deployed by hand: changes land through an approved PR to `main`,
and Flux pulls and reconciles them.

Machines and the bare cluster (OS hardening, containerd, `kubeadm init`/`join`, the first Cilium install) are built
by Ansible in [HomeLab](https://github.com/GreenMachine582/HomeLab). This repo takes over from the moment Flux is
bootstrapped.

> [!NOTE]
> **✅ M4, Platform, is done (28 Oct 2026).** The cluster runs on all four nodes, with daily etcd snapshots and a
> tested restore. Flux runs everything from `main`, including Cilium. Live:
> - the Gateway with a production wildcard cert on `192.168.50.240`
> - LB-IPAM and L2 announcements
> - `local-nvme` storage
> - the Cloudflare tunnel
> - Discord deploy notifications
> - the backup drive on rpi-02 (NFS), with daily copies of the etcd snapshots and Postgres dumps
>
> Design notes are under [Platform stack](#-platform-stack); the Cloudflare side is in
> [docs/CLOUDFLARE.md](docs/CLOUDFLARE.md).
>
> **✅ M5, the first workloads, is done.** The gth-ui playground (LAN only), shared Postgres 18 with daily dumps,
> Authentik, and Grafana with alerts to Discord are live. The alert path and a dump restore are tested. Next is M5.5,
> the public playground behind Authentik. See [docs/M5_WORKLOADS.md](docs/M5_WORKLOADS.md) and the
> [Roadmap](#️-roadmap).

**Quick links:** [🏗️ Architecture](#️-architecture) · [🗂️ Repo structure](#️-repo-structure) ·
[🧩 Platform](#-platform-stack) · [🌐 Network](#-network) · [🔐 Secrets](#-secrets) · [🔒 Security](#-security) ·
[💾 Backups](#-backups) · [📊 Monitoring](#-monitoring--notifications) · [🛠️ Working here](#️-working-in-this-repo) ·
[🗺️ Roadmap](#️-roadmap)

**Docs:** [🧩 Adding a service](docs/ADDING_A_SERVICE.md) · [🔐 Secrets](docs/SECRETS.md) ·
[🔑 Authentik](docs/AUTHENTIK.md) · [🤝 Contributing](CONTRIBUTING.md) · [☁️ Cloudflare](docs/CLOUDFLARE.md) ·
[🚨 Incidents](docs/INCIDENT.md) ·
[📦 M5 plan](docs/M5_WORKLOADS.md)

---

## 🏗️ Architecture

A single upstream Kubernetes cluster built with kubeadm, using Cilium for networking, the Gateway API and
LoadBalancer IPs. laptop-01 runs the control plane, and three Raspberry Pis are workers. They sit on one switch at a
remote site, with static LAN IPs. Everything is managed from home over Tailscale.

| Node        | Role                                              | Arch  | Host                 | Envoy |
|-------------|---------------------------------------------------|-------|----------------------|-------|
| `laptop-01` | Control plane (`NoSchedule` taint kept)           | amd64 | Old laptop, wired, Debian 13 | ✅ |
| `rpi-01`    | Worker                                            | arm64 | Raspberry Pi 4, 2 GB | ❌ |
| `rpi-02`    | Worker                                            | arm64 | Raspberry Pi 4, 8 GB | ❌ |
| `rpi-03`    | Worker, database node with local NVMe (taint from M6) | arm64 | Raspberry Pi 5, 8 GB | ✅ |

> [!IMPORTANT]
> **Envoy only runs on laptop-01 and rpi-03.** The Pi 4 kernel has a 39-bit virtual address space, and Envoy's
> tcmalloc needs 48-bit. So the Pi 4s are labelled `homelab/l7-proxy=unsupported`, and `cilium-envoy` is pinned to
> `supported`. Anything that needs L7/FQDN/TLS policy, or serves through the Gateway, must select
> `homelab/l7-proxy: supported`. In practice that's rpi-03. The Pi 4 agents run with the L7 proxy off
> (`infrastructure/configs/cilium/node-config-no-l7-proxy.yaml`); otherwise their new pods wait on an Envoy that isn't
> there and never get networking.

<details>
<summary>🔀 <b>How changes flow, and the reconciliation order</b></summary>

```
Branch ──► PR (signed commits, checks) ──► merge to main ──► Flux pulls (~1 min) ──► cluster matches git ──► Discord
```

Flux also reverts manual drift: anything changed with `kubectl edit` is put back to what git says.

```
gateway-api-crds ──► infrastructure (controllers) ──► infrastructure-configs ──► apps
```

Each layer is a Flux `Kustomization` with `dependsOn` the previous one, so CRDs and controllers exist before anything
uses them.

</details>

---

## 🗂️ Repo structure

<details open>
<summary><b>Layout</b> (✅ live, ⏳ planned)</summary>

```
homelab-cluster/
  .sops.yaml                    # age recipient + which fields get encrypted
  clusters/prod/
    flux-system/                # committed `flux install --export` + sync (HomeLab flux_bootstrap.yml)
    gateway-api.yaml            # Gateway API CRDs, SHA-pinned upstream source
    infrastructure.yaml         # → infrastructure/controllers
    infrastructure-configs.yaml # → infrastructure/configs (SOPS)
    apps.yaml                   # → apps/prod (SOPS)

  infrastructure/
    controllers/                # Helm releases
      cilium/                   # ✅ adopted from the Ansible install
      cert-manager/             # ✅
    configs/
      cert-manager/             # ✅ Let's Encrypt ClusterIssuers + Cloudflare token
      cilium/                   # ✅ LB-IPAM pool, L2 announcement policy
      cloudflared/              # ✅ the homelab tunnel
      flux-notifications/       # ✅ Discord deploy notifications
      gateway/                  # ✅ shared Gateway, wildcard cert, HTTP → HTTPS
      scheduling/               # ✅ homelab-critical PriorityClass
      storage/                  # ✅ local-nvme StorageClass

  apps/
    base/<service>/             # one folder per service: ✅ whoami, gth-playground, postgres,
                                #   authentik, monitoring; ⏳ bottlebot, greentechhub (M6), jellyfin (M7)
    prod/<service>/             # overlays + SOPS secrets

  docs/                         # ADDING_A_SERVICE.md, AUTHENTIK.md, SECRETS.md, CLOUDFLARE.md, INCIDENT.md, M5_WORKLOADS.md
```

</details>

**Conventions**
- 📁 One namespace per service, named after its `apps/base/` folder.
- 🔐 Encrypted secrets are named `*.sops.yaml`, live next to the overlay that uses them, and are listed in
  [docs/SECRETS.md](docs/SECRETS.md).
- 📌 Helm charts and images are pinned to exact versions. Upgrades go through a PR like everything else.
- 📏 Every workload sets resource requests and limits.
- 🏗️ Images are multi-arch (amd64 + arm64). The workers are Pis, and the only amd64 node is the tainted control plane.

---

## 🧩 Platform stack

| | Component | Purpose | Namespace | Status |
|---|---|---|---|---|
| 🔄 | Flux | GitOps: syncs this repo, decrypts SOPS, posts deploys to Discord | `flux-system` | ✅ |
| 🐝 | Cilium | CNI, kube-proxy replacement, Gateway API, LB-IPAM, L2 announcements | `kube-system` | ✅ |
| 🔒 | cert-manager | Let's Encrypt via Cloudflare DNS-01 | `cert-manager` | ✅ |
| 🚪 | Gateway `homelab` | One LoadBalancer IP for all LAN services, wildcard TLS | `gateway` | ✅ |
| 🚇 | cloudflared | Outbound tunnel for public routes | `cloudflared` | ✅ |
| 📈 | kube-prometheus-stack | Prometheus, Grafana, Alertmanager (slimmed, no control-plane scraping) | `monitoring` | ✅ |
| 📜 | Loki + Alloy | Log storage and collection | `monitoring` | 📋 Backlog |

<details>
<summary><b>Design notes</b> (decided in M4)</summary>

- **Domain:** `green-tech-hub.com` on Cloudflare. LAN services are `*.home.green-tech-hub.com`; public ones are
  `<name>.green-tech-hub.com` through the tunnel.
- **LAN names:** one public record, `*.home` A `192.168.50.240`, DNS only. Every device on the site LAN resolves
  every service, with no hosts files and no DNS change per service. The cost: a private IP is visible in public DNS.
  Pi-hole split horizon is in the backlog.
- **Certificates:** Let's Encrypt through cert-manager, DNS-01 against Cloudflare, so no inbound ports. One wildcard
  `*.home` certificate on the Gateway. New certificates go through `letsencrypt-staging` first (production rate
  limits are tight).
- **LoadBalancer IPs:** Cilium LB-IPAM, pool `192.168.50.240–.250`, announced by Cilium L2 (ARP). The router's DHCP
  pool was shrunk to `.30–.239` to make room.
- **Where L2 answers:** only nodes labelled `homelab/l7-proxy=supported` (laptop-01, rpi-03), because the Gateway's
  traffic goes through Envoy, which can't run on the Pi 4s.
- **Gateway:** Cilium Gateway API (CRDs imported by commit through a pinned Flux source, not vendored). One shared
  `gateway/homelab` on `192.168.50.240`: an HTTPS listener with the wildcard cert, and HTTP → HTTPS. Services attach
  an `HTTPRoute` to `sectionName: https`.
- **Storage:** `local-nvme` (no provisioner, `WaitForFirstConsumer`, `Retain`). Each workload brings its own PV
  under `/mnt/nvme/k8s/<name>` on rpi-03.
- **Public access:** cloudflared with a locally managed tunnel: ingress rules in git, credentials as a SOPS secret,
  forwarding to the Gateway inside the cluster ([docs/CLOUDFLARE.md](docs/CLOUDFLARE.md)).
- **Cilium values:** Flux owns them. HomeLab's install seed keeps only core networking; Gateway API and L2
  announcements are Flux-only, so a rebuild comes up as a plain CNI and Flux finishes it.

</details>

<details>
<summary><b>Things to know</b></summary>

- **L2 failover:** one supported node answers ARP for a pool IP at a time (a lease). If it goes down, the other
  takes over within about 15 s. With only laptop-01 and rpi-03 eligible, both down means the Gateway is unreachable.
- **After a rebuild:** if the Gateway stays `Programmed: False` once Flux has upgraded Cilium, restart
  `deploy/cilium-operator` once. It only checks for the Gateway API CRDs at start.
- **DNS-01:** cert-manager checks propagation against public resolvers (`1.1.1.1`, `8.8.8.8`), not the site router,
  so a router DNS quirk can't stall issuance.

</details>

---

## 🌐 Network

| | |
|---|---|
| 🏠 **LAN services** | `https://<name>.home.green-tech-hub.com` → Gateway `192.168.50.240`. The Cloudflare `*.home` A record is DNS only, and the wildcard cert covers every name |
| 🌍 **Public services** | `https://<name>.green-tech-hub.com` → Cloudflare → the `homelab` tunnel (outbound only, HTTP/2) → the Gateway's `https-public` listener, with its own `*.green-tech-hub.com` certificate. The public Host and SNI are kept end to end. No router port forwards |
| 🧮 **Site LAN** | `192.168.50.0/24`: node statics below `.30`, router DHCP `.30–.239`, LB-IPAM `.240–.250` |
| ☸️ **Cluster ranges** | pods `10.244.0.0/16`, Services `10.96.0.0/12`, API at `k8s-api:6443` (by name, so a subnet change isn't a rebuild) |
| 🔑 **Admin access** | `kubectl` from WSL on the main PC over Tailscale. Node SSH and Tailscale are managed in HomeLab. From home, the site LAN is only reachable while laptop-01's subnet route is approved |

Manual Cloudflare setup (token, records, tunnel) is recorded in
[CLOUDFLARE.md › Cloudflare setup](docs/CLOUDFLARE.md#-cloudflare-setup-manual).

---

## 🔐 Secrets

Secrets are encrypted in git with [SOPS](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age).
Only `data` and `stringData` are encrypted, so names and structure stay readable in PRs.

- 📒 **[docs/SECRETS.md](docs/SECRETS.md)** lists every encrypted file, where its value comes from and how to recreate
  it. Update it in the same PR as any `*.sops.yaml`.
- 🔓 The age **public** key is in `.sops.yaml`. The **private** key never enters this repo. Flux decrypts with the
  `sops-age` secret in `flux-system`, created once at bootstrap.
- 🗝️ The private key is kept offline in two places, one off-site. Losing it means every secret here is unreadable.

<details>
<summary>Create or edit a secret</summary>

```bash
# Create: encrypt through a pipe so the plaintext never touches disk
f=apps/prod/my-app/my-app.sops.yaml
kubectl create secret generic my-app --from-literal=PASSWORD="$VALUE" --dry-run=client -o yaml \
| sops --encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"

# Edit an existing secret (decrypts in your editor, re-encrypts on save)
sops apps/prod/my-app/my-app.sops.yaml
```

</details>

---

## 🔒 Security

1. 🔀 **Change control:** `main` is protected. Every change needs a PR with signed commits that pass the
   `commit-style` and `public-guard` checks, with no direct pushes, force-pushes or bypass. See
   [CONTRIBUTING.md](CONTRIBUTING.md).
2. ⬇️ **Pull-based deploys:** nothing outside the cluster pushes into it. Flux pulls from GitHub.
3. 🚫 **No inbound ports:** public traffic arrives only through the Cloudflare tunnel.
4. 🔐 **Secrets:** SOPS-encrypted at rest in git, and Kubernetes Secrets are encrypted at rest in etcd.
5. 📌 **Supply chain:** charts and images pinned; external manifests come only from SHA-pinned Flux sources; remote
   kustomize bases are blocked.
6. 🗓️ **Scheduling:** the control plane keeps its `NoSchedule` taint. The data node has no taint: its local PVs pin stateful pods there, and Postgres is protected by Guaranteed QoS
   and a `homelab-critical` PriorityClass ([M5](docs/M5_WORKLOADS.md#decisions)).
7. 🛑 **Pre-exposure checks:** only the whoami test host is public (M5.5 PR 3), and it comes off again after its test. A tunnel hostname only merges if `public-guard` passes:
   PSA `restricted`, default-deny network policy, no service account token, hardened containers
   ([Before going public](docs/ADDING_A_SERVICE.md#-before-going-public)). Anything with admin or shared-write
   features goes public only behind Authentik.
8. 🚨 **Incidents:** kill switch, revoking sessions and rotation in [docs/INCIDENT.md](docs/INCIDENT.md).
9. 📣 **Advisories:** the `goauthentik/authentik` repo is watched for security advisories on GitHub. Once `auth` is
   public, a CVE fix merges within days ([AUTHENTIK.md › Security advisories](docs/AUTHENTIK.md#-security-advisories)).
10. ⏳ **In progress (M5.5):** Cilium network policies, default-deny per namespace. Done: `gth-playground`, `cloudflared`,
    `postgres`, `authentik`. Everything else can still reach any pod (backlog).

---

## 💾 Backups

Cluster config is rebuildable from this repo. What git can't restore is data and the age key.

| Data                | Method                          | Destination                          | Frequency |
|---------------------|---------------------------------|--------------------------------------|-----------|
| Cluster config      | Git                             | GitHub                               | On merge  |
| etcd + PKI          | `etcdctl snapshot save`, keep 7 | laptop-01 ✅, fetched home ✅, backup Pi ⏳ (M4) | Daily |
| PostgreSQL          | `pg_dump` CronJob               | rpi-03 + fetched home ✅, backup Pi ⏳ | Daily     |
| age private key     | Manual offline copies           | Two locations, one off-site          | On change |

Restores are tested, not assumed: the etcd restore in M2, a Postgres restore into a separate instance in M5, and a
full rebuild in M8.

---

## 📊 Monitoring & notifications

- 💬 **Live:** Discord `#homelab-deploys` gets every pulled commit, and every applied change or failure, from Flux.
  HomeLab sends node events (boot, power loss, SSH logins, etcd snapshot failures) to Discord.
- 🚨 **Live (M5):** kube-prometheus-stack's default alert rules go to Discord `#homelab-alerts` through Alertmanager, and
  Grafana is at `grafana.home` with Authentik sign-in ([runbook](docs/M5_WORKLOADS.md#monitoring-runbook)). Rules for
  the control-plane components aren't loaded, because they aren't scraped. What it catches:

| Condition                                                        | Example rules                                    |
|------------------------------------------------------------------|--------------------------------------------------|
| Pods crash-looping or not ready, Jobs failing (`pg_dump`)        | `KubePodCrashLooping`, `KubeJobFailed`           |
| Nodes not ready, or short of memory or disk                      | `KubeNodeNotReady`, `NodeFilesystemSpaceFillingUp` |
| PVCs filling up                                                  | `KubePersistentVolumeFillingUp`                  |
| Prometheus or Alertmanager itself broken                         | `PrometheusRuleFailures`, `AlertmanagerFailedToSendAlerts` |

> [!WARNING]
> Known gap: monitoring runs inside the cluster, so nothing alerts if the whole site goes quiet. An external Uptime
> Kuma is in the backlog.

---

## 🛠️ Working in this repo

**Tools:** `kubectl`, `flux`, `sops`, `age`, `cloudflared`, run from WSL on the main PC. HomeLab's
`controller.yml` installs them at pinned versions.

```bash
flux get kustomizations                                   # what Flux is doing
flux get helmreleases -A
flux reconcile kustomization flux-system --with-source    # sync now instead of waiting
kubectl kustomize apps/prod                               # render before opening a PR
```

- 🤝 **Changes:** branch, signed Conventional Commits, PR. See [CONTRIBUTING.md](CONTRIBUTING.md).
- 🧩 **Adding a service:** follow [docs/ADDING_A_SERVICE.md](docs/ADDING_A_SERVICE.md).

<details>
<summary>🔄 <b>Bootstrapping and upgrading Flux</b></summary>

**Bootstrapping:** this doesn't use `flux bootstrap github`. Flux's manifests live in `clusters/prod/flux-system`:
`gotk-components.yaml` is `flux install --export`, and `gotk-sync.yaml` is the GitRepository + Kustomization.
HomeLab's `playbooks/flux_bootstrap.yml` applies them once, with the `sops-age` secret. The repo is public, so Flux
needs no deploy key, and nothing pushes to `main` outside a PR. Re-run the playbook to repair a broken Flux.

**Upgrading:** in a PR, regenerate `clusters/prod/flux-system/gotk-components.yaml` with the new CLI
(`flux install --export > …`). Bump `flux_version` in HomeLab's `group_vars/k8s.yml`. Flux upgrades itself when the
PR is merged.

</details>

---

## 🗺️ Roadmap

| Milestone | Scope                                                        | Status  |
|-----------|--------------------------------------------------------------|---------|
| M0        | Repo, age key, discord-gateway removed, splits frozen        | ✅ Done |
| M1        | Nodes on the LAN: switch moved, nodes bootstrapped by Ansible | ✅ Done |
| M2        | kubeadm + Cilium cluster, etcd snapshot restore tested       | ✅ Done |
| M3        | Flux bootstrap, SOPS, branch protection, Cilium adopted      | ✅ Done |
| M4        | Gateway, LB-IPAM, cert-manager, storage, cloudflared, backup NFS ([plan, archived](https://github.com/GreenMachine582/homelab-cluster/blob/96c1ec73b2e46771afb2eed673d320223b871138/docs/M4_PLATFORM.md)) | ✅ Done |
| M5        | gth-ui playground, Postgres, Authentik, Grafana + minimal alerting ([plan](docs/M5_WORKLOADS.md)) | ✅ Done |
| M5.5      | Public playground behind Authentik: network policies, public listener, invite-only sign-up, hardening | 🚧 In progress |
| M6        | BottleBot, GreenTechHub (multi-arch GHCR builds)             | ⏳ Pending |
| M7        | Jellyfin and remaining services                              | ⏳ Pending |
| M8        | Cutover from Compose, full DR rebuild test                   | ⏳ Pending |

<details>
<summary>📋 Backlog</summary>

Pi-hole (split-horizon DNS), external Uptime Kuma (priority), Loki + Alloy, control-plane metrics, Camunda 8, n8n, control-plane HA, CloudNativePG, VLAN
segmentation, Longhorn, network policies for the namespaces M5.5 doesn't cover, GPU workloads.

</details>

---

## 🔗 Related

- [HomeLab](https://github.com/GreenMachine582/HomeLab): Ansible for node provisioning, cluster bootstrap and the
  controller toolchain.
