# homelab-cluster

![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?logo=kubernetes&logoColor=white)
![Flux](https://img.shields.io/badge/Flux-5468FF?logo=flux&logoColor=white)
![Cilium](https://img.shields.io/badge/Cilium-F8C517?logo=cilium&logoColor=black)
![Cloudflare](https://img.shields.io/badge/Cloudflare-F38020?logo=cloudflare&logoColor=white)
![SOPS + age](https://img.shields.io/badge/secrets-SOPS%20%2B%20age-555555)
![Self-hosted](https://img.shields.io/badge/self--hosted-homelab-4A90D9)
![Status](https://img.shields.io/badge/status-M4_Platform-yellow)

GitOps repository for the homelab Kubernetes cluster. Everything running inside the cluster is declared here and
applied by [Flux](https://fluxcd.io). Nothing is deployed by hand: changes land through an approved PR to `main`,
and Flux pulls and reconciles them.

Machines and the bare cluster (OS hardening, containerd, `kubeadm init`/`join`, the first Cilium install) are built
by Ansible in [HomeLab](https://github.com/GreenMachine582/HomeLab). This repo takes over from the moment Flux is
bootstrapped.

> [!NOTE]
> **Status: M4, Platform. Everything is live except the backup target.** The cluster runs on all four nodes,
> with daily etcd snapshots and a tested restore. Flux runs everything from `main`, including Cilium. Live:
> - the Gateway with a production wildcard cert on `192.168.50.240`
> - LB-IPAM and L2 announcements
> - `local-nvme` storage
> - the Cloudflare tunnel
> - Discord deploy notifications
>
> M4 closes once the backup target is in place. See [docs/M4_PLATFORM.md](docs/M4_PLATFORM.md).
>
> **M5, the first workloads, is in progress.** The gth-ui playground is live, LAN only, at
> `https://playground.home.green-tech-hub.com`. Postgres, Authentik and Grafana are next. See
> [docs/M5_WORKLOADS.md](docs/M5_WORKLOADS.md) and the [Roadmap](#️-roadmap).

**Quick links:** [🏗️ Architecture](#️-architecture) · [🗂️ Repo structure](#️-repo-structure) ·
[🧩 Platform](#-platform-stack) · [🌐 Network](#-network) · [🔐 Secrets](#-secrets) · [🔒 Security](#-security) ·
[💾 Backups](#-backups) · [📊 Monitoring](#-monitoring--notifications) · [🛠️ Working here](#️-working-in-this-repo) ·
[🗺️ Roadmap](#️-roadmap)

**Docs:** [🧩 Adding a service](docs/ADDING_A_SERVICE.md) · [🔐 Secrets](docs/SECRETS.md) ·
[🤝 Contributing](CONTRIBUTING.md) · [🧱 M4 plan + Cloudflare setup](docs/M4_PLATFORM.md) ·
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
                                # ⏳ kube-prometheus-stack (M5)
    configs/
      cert-manager/             # ✅ Let's Encrypt ClusterIssuers + Cloudflare token
      cilium/                   # ✅ LB-IPAM pool, L2 announcement policy
      cloudflared/              # ✅ the homelab tunnel
      flux-notifications/       # ✅ Discord deploy notifications
      gateway/                  # ✅ shared Gateway, wildcard cert, HTTP → HTTPS
      storage/                  # ✅ local-nvme StorageClass

  apps/
    base/<service>/             # one folder per service: ✅ whoami, gth-playground; ⏳ postgres,
                                #   authentik (M5), bottlebot, greentechhub (M6), jellyfin (M7)
    prod/<service>/             # overlays + SOPS secrets

  docs/                         # ADDING_A_SERVICE.md, SECRETS.md, M4_PLATFORM.md, M5_WORKLOADS.md
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
| 📈 | kube-prometheus-stack | Prometheus, Grafana, Alertmanager (slimmed, no control-plane scraping) | `monitoring` | ⏳ M5 |
| 📜 | Loki + Alloy | Log storage and collection | `monitoring` | 📋 Backlog |

---

## 🌐 Network

| | |
|---|---|
| 🏠 **LAN services** | `https://<name>.home.green-tech-hub.com` → Gateway `192.168.50.240`. The Cloudflare `*.home` A record is DNS only, and the wildcard cert covers every name |
| 🌍 **Public services** | `https://<name>.green-tech-hub.com` → Cloudflare → the `homelab` tunnel (outbound only, HTTP/2) → the Gateway. No router port forwards |
| 🧮 **Site LAN** | `192.168.50.0/24`: node statics below `.30`, router DHCP `.30–.239`, LB-IPAM `.240–.250` |
| ☸️ **Cluster ranges** | pods `10.244.0.0/16`, Services `10.96.0.0/12`, API at `k8s-api:6443` (by name, so a subnet change isn't a rebuild) |
| 🔑 **Admin access** | `kubectl` from WSL on the main PC over Tailscale. Node SSH and Tailscale are managed in HomeLab. From home, the site LAN is only reachable while laptop-01's subnet route is approved |

Manual Cloudflare setup (token, records, tunnel) is recorded in
[M4_PLATFORM.md › Cloudflare setup](docs/M4_PLATFORM.md#cloudflare-setup-manual).

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
   `commit-style` check, with no direct pushes, force-pushes or bypass. See [CONTRIBUTING.md](CONTRIBUTING.md).
2. ⬇️ **Pull-based deploys:** nothing outside the cluster pushes into it. Flux pulls from GitHub.
3. 🚫 **No inbound ports:** public traffic arrives only through the Cloudflare tunnel.
4. 🔐 **Secrets:** SOPS-encrypted at rest in git, and Kubernetes Secrets are encrypted at rest in etcd.
5. 📌 **Supply chain:** charts and images pinned; external manifests come only from SHA-pinned Flux sources; remote
   kustomize bases are blocked.
6. 🗓️ **Scheduling:** the control plane keeps its `NoSchedule` taint. The data node has no taint: its local PVs pin stateful pods there, and Postgres is protected by Guaranteed QoS
   and a `homelab-critical` PriorityClass ([M5](docs/M5_WORKLOADS.md#decisions)).
7. ⏳ **Backlog:** Cilium network policies, default-deny per namespace. There are none yet, so any pod can reach any
   other. The only public route is `whoami`. A service gets a tunnel rule only after the pre-exposure checks (backlog),
   and anything with admin or shared-write features only behind Authentik.

---

## 💾 Backups

Cluster config is rebuildable from this repo. What git can't restore is data and the age key.

| Data                | Method                          | Destination                          | Frequency |
|---------------------|---------------------------------|--------------------------------------|-----------|
| Cluster config      | Git                             | GitHub                               | On merge  |
| etcd + PKI          | `etcdctl snapshot save`, keep 7 | laptop-01 ✅, fetched home ✅, backup Pi ⏳ (M4) | Daily |
| PostgreSQL          | `pg_dump` CronJob               | rpi-03 + fetched home ⏳ (M5), backup Pi ⏳ | Daily     |
| age private key     | Manual offline copies           | Two locations, one off-site          | On change |

Restores are tested, not assumed: the etcd restore in M2, a Postgres restore into a separate instance in M5, and a
full rebuild in M8.

---

## 📊 Monitoring & notifications

- 💬 **Live:** Discord `#homelab-deploys` gets every pulled commit, and every applied change or failure, from Flux.
  HomeLab sends node events (boot, power loss, SSH logins, etcd snapshot failures) to Discord.
- ⏳ **M5:** in-cluster alerting to Discord `#homelab-alerts`:

| Severity | Condition                                          | Channel |
|----------|----------------------------------------------------|---------|
| Critical | Node not ready, crash loop, backup job failed      | Discord |
| Warning  | CPU/memory > 80%, PVC > 80% full, cert expiry      | Discord |
| Info     | Upgrade available                                  | Discord |

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
| M4        | Gateway, LB-IPAM, cert-manager, storage, cloudflared, backup NFS ([plan](docs/M4_PLATFORM.md)) | 🚧 Backup target left |
| M5        | gth-ui playground, Postgres, Authentik, Grafana + minimal alerting ([plan](docs/M5_WORKLOADS.md)) | 🚧 In progress |
| M6        | BottleBot, GreenTechHub (multi-arch GHCR builds)             | ⏳ Pending |
| M7        | Jellyfin and remaining services                              | ⏳ Pending |
| M8        | Cutover from Compose, full DR rebuild test                   | ⏳ Pending |

<details>
<summary>📋 Backlog</summary>

Pi-hole (split-horizon DNS), external Uptime Kuma (priority), Loki + Alloy, control-plane metrics, Camunda 8, n8n, control-plane HA, CloudNativePG, VLAN
segmentation, Longhorn, network policies, pre-exposure checks (a checklist and a CI guard before any tunnel rule), GPU
workloads.

</details>

---

## 🔗 Related

- [HomeLab](https://github.com/GreenMachine582/HomeLab): Ansible for node provisioning, cluster bootstrap and the
  controller toolchain.
