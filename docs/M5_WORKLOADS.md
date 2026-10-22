# M5: First workloads and minimal alerting

The first real services on the cluster: the gth-ui playground, Postgres, Authentik, and Grafana with just enough
alerting to know when something breaks. This is the working plan. Each item is one PR, and its status is updated
here as it lands.

M5 was re-scoped on 22 Oct 2026. It was full observability (kube-prometheus-stack, Loki, Alloy, in-cluster Uptime
Kuma); it now ships workloads first and keeps only the monitoring that the cluster can't do without. The old M6
(BottleBot, GreenTechHub) and M7 (Jellyfin and the rest) follow, renumbered in the migration plan.

**Exit test:**
- The playground is reachable at `https://playground.home.green-tech-hub.com`.
- Authentik login works through the Gateway, and Grafana's login goes through Authentik.
- A crash-looping pod and a failed `pg_dump` Job each raise an alert in Discord `#homelab-alerts`.
- A dump restores into a throwaway Postgres.

## Decisions

| Topic | Decision |
|---|---|
| Scope | Workloads first: gth-ui playground → Postgres → Authentik → Grafana. Monitoring is cut to what Flux's deploy notifications can't cover: crash loops, nodes not ready, full PVCs, failed Jobs |
| Monitoring | `kube-prometheus-stack`, slimmed down: Prometheus (7 days retention), Alertmanager, kube-state-metrics, node-exporter, Grafana. Default rules kept, minus those for components not scraped |
| Control-plane scraping | Off (`kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy`). kubeadm binds their metrics to `127.0.0.1`, so scraping them would need a kubeadm and firewall change in HomeLab. Not worth it yet |
| Deferred | Loki and Alloy (`kubectl logs` is enough at this scale). Moved to the backlog |
| Dropped | In-cluster Uptime Kuma. It can't report the one failure that matters at a remote site, the site going quiet. The external Uptime Kuma at home stays the backlog priority |
| Alerts | Alertmanager's native Discord receiver, to a new `#homelab-alerts` channel. Separate from `#homelab-deploys`, so alerts don't get lost in deploy noise |
| Images | Multi-arch (amd64 + arm64) on GHCR, built by GitHub Actions with buildx. The gth-ui playground is the first pipeline; BottleBot and GreenTechHub reuse it in M6. Packages are public, so no pull secret |
| Playground | LAN only, `playground.home.green-tech-hub.com`. No tunnel rule: it has a fake persona switcher (admin included) and fixture data |
| Data node | rpi-03 stays the data node: the only node with real storage (NVMe). The other Pis boot from SD, and laptop-01 keeps its control-plane taint. Every stateful PV lives under `/mnt/nvme/k8s/<name>` on rpi-03 |
| Data-node taint | **None.** The `local-nvme` PVs' node affinity already pins stateful pods to rpi-03. A taint would only push other pods off the strongest worker (Pi 5, 8 GB), which also runs cloudflared and is one of the two Envoy nodes, and leave general pods on rpi-01 (2 GB) and rpi-02. Revisit when pc-01 or another big worker joins, or if rpi-03 shows contention |
| Protecting Postgres | Memory requests equal limits (Guaranteed QoS), and a `homelab-critical` PriorityClass for Postgres and Authentik, so other pods are evicted first under memory pressure |
| Postgres | Official `postgres` image, StatefulSet with one replica, a `local-nvme` PV on rpi-03, ClusterIP Service. One database and role per app, created by a Job from SOPS secrets (the image's init scripts run only on first start). CloudNativePG stays in the backlog |
| Postgres backups | Daily `pg_dumpall` CronJob, gzipped, keep 7, to a second PV on rpi-03. Fetched home by a HomeLab playbook, like etcd snapshots. Moves to the NFS backup target when [M4](M4_PLATFORM.md) PR 9 lands |
| Authentik | Official `goauthentik` Helm chart, external Postgres, `auth.home.green-tech-hub.com`. Bootstrap admin password and secret key as SOPS secrets |
| Grafana login | Authentik OIDC (`generic_oauth`). The local admin stays as break-glass |
| Placement | Nothing new on rpi-01 (2 GB). Postgres, Prometheus and Grafana sit on rpi-03 because of their PVs |

## PRs

| # | Repo | PR | Needs | Status |
|---|---|---|---|---|
| 0 | homelab-cluster | **Docs**: this plan, README roadmap | — | This PR |
| 1 | greentechhub-ui | **Playground image**: `playground/Dockerfile` (Python slim, non-root, uvicorn on 8500), multi-arch GHCR workflow, tagged by release version and commit | — | To do |
| 2 | homelab-cluster | **gth-playground**: namespace, Deployment, Service, `HTTPRoute` on `playground.home`, as in [ADDING_A_SERVICE.md](ADDING_A_SERVICE.md). Image pinned by version and digest | 1; GHCR package made public | To do |
| 3 | HomeLab | **Local volume directories**: `k8s_local_volumes` on rpi-03 creates `/mnt/nvme/k8s/<name>` with owner and mode (`postgres`, `postgres-dumps`, `prometheus`, `grafana`). Updates the `k8s_data_taint_enabled` comment | — | To do |
| 4 | both | **Postgres**: StatefulSet, PV and PVC, Service, superuser secret, per-app database Job, `pg_dump` CronJob, `homelab-critical` PriorityClass. HomeLab: `pg_dump_fetch.yml` copies dumps home. Restore rehearsal documented | 3 | To do |
| 5 | homelab-cluster | **Authentik**: HelmRepository + HelmRelease on external Postgres, `HTTPRoute` on `auth.home`, SOPS secrets; namespace added to the `homelab-deploys` alert | 4 | To do |
| 6 | homelab-cluster | **Monitoring + Grafana**: slimmed `kube-prometheus-stack`, Prometheus and Grafana PVs, Alertmanager → `#homelab-alerts`, Grafana on `grafana.home` with Authentik OIDC | 3, 5; `#homelab-alerts` webhook; Grafana application in Authentik | To do |
| 7 | both | **Exit + docs**: crash-loop and failed-Job alert tests (a temporary `test/` PR), dump restore, M5 marked done | 1–6 | To do |

Order: 1 and 3 can start in any order. 2 needs 1. Then 4 → 5 → 6 → 7.

## What's needed from you

1. **A Discord `#homelab-alerts` channel and webhook** (before PR 6). Stored as a SOPS secret, recorded in
   [SECRETS.md](SECRETS.md).
2. **Make the GHCR package public** after its first push (GitHub → Packages → `greentechhub-ui-playground` →
   Package settings → Change visibility).
3. **Authentik first login** after PR 5, then create the Grafana OAuth2/OpenID provider and application (before
   PR 6). The steps are recorded here once done, so a rebuild can repeat them.

## Things to watch

- **Dumps on the same node:** until the backup drive exists, `pg_dump` writes to rpi-03, next to the database. The
  copy fetched home is the only off-node copy. Point the CronJob at NFS as soon as M4 PR 9 lands.
- **rpi-03 holds all state:** Postgres, its dumps, Prometheus and Grafana. If rpi-03 is down, so are Authentik,
  Grafana and anything with a database, and public access too (cloudflared runs there).
- **Public playground off:** the persona switcher lets anyone act as an admin of the demo. Keep it off the tunnel,
  or put it behind Authentik before adding one.
- **No control-plane metrics:** etcd, scheduler and controller-manager problems won't alert. HomeLab's etcd snapshot
  failures still go to Discord.
- **Monitoring inside the cluster:** nothing alerts if the whole site goes quiet. That's the external Uptime Kuma's
  job (backlog, priority).
