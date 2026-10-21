# homelab-cluster

![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?logo=kubernetes&logoColor=white)
![Flux](https://img.shields.io/badge/Flux-5468FF?logo=flux&logoColor=white)
![Cilium](https://img.shields.io/badge/Cilium-F8C517?logo=cilium&logoColor=black)
![SOPS + age](https://img.shields.io/badge/secrets-SOPS%20%2B%20age-555555)
![Self-hosted](https://img.shields.io/badge/self--hosted-homelab-4A90D9)
![Status](https://img.shields.io/badge/status-M4_Platform-yellow)

GitOps repository for the homelab Kubernetes cluster. Everything running inside the cluster is declared here and
applied by [Flux](https://fluxcd.io). Nothing is deployed by hand: changes land through an approved PR to `main`,
and Flux pulls and reconciles them.

Machines and the bare cluster (OS hardening, containerd, `kubeadm init`/`join`, Cilium install) are built by Ansible in
[HomeLab](https://github.com/GreenMachine582/HomeLab). This repo takes over from the moment Flux is bootstrapped.

**⚠️ Status: M4 — Platform.** The cluster is up on all four nodes, with daily etcd snapshots and a tested restore.
Flux runs everything from `main`, including Cilium, and SOPS secrets are proven. M4 adds LoadBalancer IPs, the
Gateway with TLS, storage, the Cloudflare tunnel and a backup target: see [docs/M4_PLATFORM.md](docs/M4_PLATFORM.md)
and the [Roadmap](#️-roadmap).

**Quick links:** [🏗️ Architecture](#️-architecture-overview) · [🗂️ Repo Structure](#️-repo-structure) ·
[🧩 Platform Stack](#-platform-stack) · [🔐 Secrets](#-secrets) · [🌐 Network](#-network) · [🔒 Security](#-security) ·
[💾 Backups](#-backup-strategy) · [📊 Monitoring](#-monitoring--alerting) · [🛠️ Working in this repo](#️-working-in-this-repo) ·
[🗺️ Roadmap](#️-roadmap)

---

## 🏗️ Architecture Overview

A single upstream Kubernetes cluster built with kubeadm, using Cilium for networking, Gateway API and LoadBalancer IPs.
laptop-01 runs the control plane and three Raspberry Pis are workers, on one switch at a remote site with static
LAN IPs. Everything is managed from home over Tailscale (Ansible, kubectl, a subnet route to the site LAN).

| Node        | Role                                       | Arch  | Host                 | Status     |
|-------------|--------------------------------------------|-------|----------------------|------------|
| `laptop-01` | Control plane (taint kept)                 | amd64 | Old laptop, wired    | Joined (Debian 13) |
| `rpi-01`    | Worker, no Envoy (see below)               | arm64 | Raspberry Pi 4, 2 GB | Joined (Raspberry Pi OS trixie) |
| `rpi-02`    | Worker, no Envoy (see below)               | arm64 | Raspberry Pi 4, 8 GB | Joined (Raspberry Pi OS trixie) |
| `rpi-03`    | Worker, tainted for databases (local NVMe) | arm64 | Raspberry Pi 5, 8 GB | Joined (Raspberry Pi OS trixie) |

**Envoy only runs on laptop-01 and rpi-03.** The Raspberry Pi kernel for the Pi 4 has a 39-bit virtual address
space and Envoy's tcmalloc needs 48-bit, so the Pi 4s are labelled `homelab/l7-proxy=unsupported` and the
`cilium-envoy` DaemonSet is pinned to `homelab/l7-proxy=supported`
([`infrastructure/controllers/cilium/helmrelease.yaml`](infrastructure/controllers/cilium/helmrelease.yaml)).
Anything that needs L7/FQDN/TLS network policy, or serves through the Gateway, must select that label.

Outside the cluster: DNS comes from the site router, and backups go to external drives on a Pi (M4) with a copy
fetched home. The API server is
addressed by hostname (`controlPlaneEndpoint`), not IP, so a router or subnet change doesn't mean a rebuild.

### How changes flow

```
Branch ──► PR (signed commits, checks) ──► merge to main ──► Flux pulls (~1 min) ──► cluster matches git
```

Flux also reverts manual drift: anything changed with `kubectl edit` is put back to what git says.

### Reconciliation order

```
flux-system ──► infrastructure/controllers ──► infrastructure/configs ──► apps
```

Each layer is a Flux `Kustomization` with `dependsOn` the previous one, so CRDs and controllers exist before anything
uses them.

---

## 🗂️ Repo Structure

```
homelab-cluster/
  README.md
  .sops.yaml                  # age recipient + which files/fields get encrypted
  .gitignore

  clusters/
    prod/
      flux-system/            # Committed `flux install --export` + sync, applied by HomeLab flux_bootstrap.yml
      infrastructure.yaml     # Kustomization -> infrastructure/controllers (configs from M4)
      apps.yaml               # Kustomization -> apps/prod (dependsOn infrastructure)

  infrastructure/
    controllers/              # Helm releases: cilium (adopted from Ansible install), cert-manager,
                              # kube-prometheus-stack, loki, alloy
    configs/                  # Gateway + GatewayClass, LB-IPAM pools, cert issuers,
                              # local-storage StorageClass + PVs

  apps/
    base/                     # One folder per service, environment-agnostic
      cloudflared/
      postgres/               # StatefulSet, Service, pg_dump CronJob
      authentik/
      bottlebot/
      greentechhub/
      jellyfin/
      uptime-kuma/
    prod/                     # Kustomize overlays + SOPS-encrypted secrets per service

  docs/                       # Runbooks: bootstrap, DR, adding a service
```

**Conventions**

- One namespace per service, named after its `apps/base/` folder.
- Encrypted secrets are named `*.sops.yaml` and live next to the overlay that uses them.
- Helm charts are pinned to exact versions; upgrades go through a PR like everything else.
- Every workload sets resource requests and limits.
- Images are multi-arch (amd64 + arm64): workers are Pis, and the only amd64 node is the tainted control plane.

---

## 🧩 Platform Stack

| Component             | Purpose                                         | Namespace         |
|-----------------------|-------------------------------------------------|-------------------|
| Flux                  | GitOps: syncs this repo, decrypts SOPS          | `flux-system`     |
| Cilium                | CNI, kube-proxy replacement, Gateway API, LB-IPAM | `kube-system`   |
| cert-manager          | TLS certificates                                | `cert-manager`    |
| kube-prometheus-stack | Prometheus, Grafana, Alertmanager               | `monitoring`      |
| Loki + Alloy          | Log storage and collection                      | `monitoring`      |
| cloudflared           | Outbound tunnel for public routes               | `cloudflared`     |
| Uptime Kuma           | Endpoint uptime checks                          | `uptime-kuma`     |

---

## 🔐 Secrets

Secrets are encrypted in git with [SOPS](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age).
Only `data` and `stringData` fields are encrypted, so resource names and structure stay readable in PRs.

```bash
# Create a secret, encrypting it through a pipe so the plaintext never touches disk
f=apps/prod/my-app/my-app.sops.yaml
kubectl create secret generic my-app --from-literal=PASSWORD="$VALUE" --dry-run=client -o yaml \
| sops --encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"

# Edit an existing secret (decrypts in your editor, re-encrypts on save)
sops apps/prod/my-app/my-app.sops.yaml
```

- **[docs/SECRETS.md](docs/SECRETS.md)** lists every encrypted file, where its value comes from and how to
  recreate it. Update it in the same PR as any `*.sops.yaml`.
- The age **public** key is in `.sops.yaml`. The **private** key never enters this repo.
- Flux decrypts using the `sops-age` secret in `flux-system`, created once at bootstrap.
- The private key is kept offline in two places, one off-site. Losing it means every secret here is unreadable.

---

## 🌐 Network

- **OS:** Debian 13 (trixie) on every node: Debian on laptop-01, Raspberry Pi OS Lite on the Pis.
- **DNS:** nodes use the router's DNS. In-cluster names resolve via CoreDNS. Pi-hole is backlogged.
- **LAN services:** exposed through a Cilium Gateway on an LB-IPAM address outside the router's DHCP pool.
- **Public services:** reach the cluster only through cloudflared's outbound tunnel. No router port forwards.
- **Cluster ranges:** pods 10.244.0.0/16, Services 10.96.0.0/12; API at `k8s-api:6443`.
- **Admin access:** `kubectl` from the main PC; node SSH and Tailscale are managed in HomeLab.

---

## 🔒 Security

1. **Change control:** `main` is protected. Every change needs a PR with signed commits that pass the
   `commit-style` check. No direct pushes, force-pushes or bypass. See [CONTRIBUTING.md](CONTRIBUTING.md).
2. **Pull-based deploys:** nothing outside the cluster pushes into it. Flux pulls from GitHub.
3. **No inbound ports:** public traffic arrives through the Cloudflare tunnel only.
4. **Secrets:** SOPS-encrypted at rest in git; Kubernetes Secrets encrypted at rest in etcd.
5. **Scheduling:** the control plane keeps its `NoSchedule` taint; the data node is tainted for databases only.
6. **Backlog:** Cilium network policies, default-deny per namespace.

---

## 💾 Backup Strategy

Cluster config is rebuildable from this repo. What git can't restore is data and the age key.

| Data                | Method                        | Destination                 | Frequency |
|---------------------|-------------------------------|-----------------------------|-----------|
| Cluster config      | Git                           | GitHub                      | On merge  |
| etcd                | `etcdctl snapshot save`, keep 7 | Backup Pi (M4)            | Daily     |
| PostgreSQL          | `pg_dump` CronJob             | Backup Pi, off the data node (M4) | Daily |
| age private key     | Manual offline copies         | Two locations, one off-site | On change |

Restores are tested, not assumed: etcd restore in M2, Postgres restore into a separate instance in M6, full rebuild in M8.

---

## 📊 Monitoring & Alerting

| Severity | Condition                                          | Channel |
|----------|----------------------------------------------------|---------|
| Critical | Node not ready, crash loop, backup job failed      | Discord |
| Warning  | CPU/memory > 80%, PVC > 80% full, cert expiry      | Discord |
| Info     | Flux reconciliation failed, upgrade available      | Discord |

Known gap: monitoring runs inside the cluster, so nothing alerts if the control-plane host itself goes down. An external
Uptime Kuma on a Pi is in the backlog.

---

## 🛠️ Working in this repo

**Tools:** `kubectl`, `flux`, `sops`, `age`, `kustomize`, `helm` (run from WSL on the main PC; HomeLab's
`controller.yml` installs kubectl, flux, sops and age).

**Bootstrapping Flux:** not `flux bootstrap github`. Flux's manifests live in `clusters/prod/flux-system`
(`gotk-components.yaml` = `flux install --export`, `gotk-sync.yaml` = GitRepository + Kustomization), and HomeLab's
`playbooks/flux_bootstrap.yml` applies them once with the `sops-age` secret. The repo is public, so Flux needs no
deploy key, and nothing pushes to `main` outside a PR. Re-run the playbook to repair a broken Flux.

**Upgrading Flux:** in a PR, regenerate `clusters/prod/flux-system/gotk-components.yaml` with the new CLI
(`flux install --export > …`), and bump `flux_version` in HomeLab's `group_vars/k8s.yml`. Flux upgrades itself
when the PR is merged.

```bash
# Check what Flux is doing
flux get kustomizations
flux get helmreleases -A

# Force a sync after merging instead of waiting
flux reconcile kustomization apps --with-source

# Render an overlay locally before opening a PR
kustomize build apps/prod/<service>
```

**Changes:** branch, signed Conventional Commits, PR. See [CONTRIBUTING.md](CONTRIBUTING.md).

**Adding a service:** create `apps/base/<service>/`, add an overlay in `apps/prod/<service>/` with any `*.sops.yaml`
secrets, reference it from `apps/prod/kustomization.yaml`, open a PR.

---

## 🗺️ Roadmap

| Milestone | Scope                                                        | Status  |
|-----------|--------------------------------------------------------------|---------|
| M0        | Repo, age key, discord-gateway removed, splits frozen        | ✅ Done |
| M1        | Nodes on the LAN: switch moved, nodes bootstrapped by Ansible | ✅ Done |
| M2        | kubeadm + Cilium cluster, etcd snapshot restore tested       | ✅ Done |
| M3        | Flux bootstrap, SOPS, branch protection, Cilium adopted      | ✅ Done |
| M4        | Gateway, LB-IPAM, cert-manager, storage, cloudflared, backup NFS ([plan](docs/M4_PLATFORM.md)) | 🚧 In progress |
| M5        | Prometheus, Grafana, Loki, Alloy, Uptime Kuma                | ⏳ Pending |
| M6        | Multi-arch builds; BottleBot, GreenTechHub, Postgres, Authentik | ⏳ Pending |
| M7        | Jellyfin and remaining services                              | ⏳ Pending |
| M8        | Cutover from Compose, full DR rebuild test                   | ⏳ Pending |

**Backlog:** Pi-hole, external Uptime Kuma, Camunda 8, n8n, control-plane HA, CloudNativePG, VLAN segmentation,
Longhorn, network policies, GPU workloads.

---

## Related

- [HomeLab](https://github.com/GreenMachine582/HomeLab) — Ansible: node provisioning and cluster bootstrap
