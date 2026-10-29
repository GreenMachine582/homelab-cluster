# M5: First workloads and minimal alerting

The first real services on the cluster: the gth-ui playground, Postgres, Authentik, and Grafana with just enough
alerting to know when something breaks. This is the working plan. Each item is one PR, and its status is updated
here as it lands.

M5 was re-scoped on 22 Oct 2026. It was full observability (kube-prometheus-stack, Loki, Alloy, in-cluster Uptime
Kuma); it now ships workloads first and keeps only the monitoring that the cluster can't do without. The old M6
(BottleBot, GreenTechHub) and M7 (Jellyfin and the rest) follow, renumbered in the migration plan.

> [!NOTE]
> **✅ M5 is done (28 Oct 2026).** Every exit test passed. M5.5, the public playground behind Authentik,
> is in progress (migration plan): its pre-exposure checks took whoami off the tunnel, so nothing is public now. M4 is done too, since its backup drive went live on 28 Oct.

**Exit test:**
- [x] The playground is reachable at `https://playground.home.green-tech-hub.com`.
- [x] Authentik login works through the Gateway, and Grafana's login goes through Authentik (28 Oct, after
  [#46](https://github.com/GreenMachine582/homelab-cluster/pull/46)).
- [x] A crash-looping pod and a failed `pg_dump` Job each raise an alert in Discord `#homelab-alerts` (28 Oct,
  HomeLab `alert_test.yml`: KubePodCrashLooping, KubeJobFailed, and KubePodNotReady with them).
- [x] A dump restores into a throwaway Postgres (28 Oct, HomeLab `pg_restore_test.yml`, from the copy fetched home).

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
| Playground | LAN only, `playground.home.green-tech-hub.com`. No tunnel rule: it has a fake persona switcher (admin included), and any visitor can change demo state that every visitor sees. `playground.green-tech-hub.com` comes later, and only behind Authentik (every user signed in, invite-only). That's scheduled as M5.5 in the migration plan, after this milestone's exit, with the pre-exposure checks first |
| Data node | rpi-03 stays the data node: the only node with real storage (NVMe). The other Pis boot from SD, and laptop-01 keeps its control-plane taint. Every stateful PV lives under `/mnt/nvme/k8s/<name>` on rpi-03 |
| Data-node taint | **None.** The `local-nvme` PVs' node affinity already pins stateful pods to rpi-03. A taint would only push other pods off the strongest worker (Pi 5, 8 GB), which also runs cloudflared and is one of the two Envoy nodes, and leave general pods on rpi-01 (2 GB) and rpi-02. Revisit when pc-01 or another big worker joins, or if rpi-03 shows contention |
| Protecting Postgres | Memory requests equal limits (Guaranteed QoS), and a `homelab-critical` PriorityClass for Postgres and Authentik, so other pods are evicted first under memory pressure |
| Postgres | Official `postgres` image, StatefulSet with one replica, a `local-nvme` PV on rpi-03, ClusterIP Service. One database and role per app, created by a Job from SOPS secrets (the image's init scripts run only on first start). CloudNativePG stays in the backlog |
| Postgres backups | Daily `pg_dumpall` CronJob, gzipped, keep 7, to a second PV on rpi-03. Copied daily to the backup drive on rpi-02 by `pg-dump-offnode` (NFS, keep 30; HomeLab `docs/K8S_CLUSTER.md` › Backup drive), and fetched home by a HomeLab playbook, like etcd snapshots |
| Authentik | Official `goauthentik` Helm chart, external Postgres, `auth.home.green-tech-hub.com`. Bootstrap admin password and secret key as SOPS secrets |
| Grafana login | Authentik OIDC (`generic_oauth`) with `auto_login`: no Grafana login page, opening Grafana goes straight to Authentik. The local admin stays as break-glass, behind `/login?disableAutoLogin=true` |
| Placement | Nothing new on rpi-01 (2 GB). Postgres, Prometheus and Grafana sit on rpi-03 because of their PVs |

## PRs

| # | Repo | PR | Needs | Status |
|---|---|---|---|---|
| 0 | homelab-cluster | **Docs**: this plan, README roadmap | — | [#22](https://github.com/GreenMachine582/homelab-cluster/pull/22) |
| 1 | greentechhub-ui | **Playground image**: `playground/Dockerfile` (Python slim, non-root, uvicorn on 8500), multi-arch GHCR workflow, tagged by release version and commit | — | greentechhub-ui [#129](https://github.com/GreenMachine582/greentechhub-ui/pull/129); released in 0.20.0 |
| 2 | homelab-cluster | **gth-playground**: namespace, Deployment, Service, `HTTPRoute` on `playground.home`, as in [ADDING_A_SERVICE.md](ADDING_A_SERVICE.md). Image pinned by version and digest (`0.20.0@sha256:…`; Renovate automerges releases) | 1; GHCR package made public (done) | [#23](https://github.com/GreenMachine582/homelab-cluster/pull/23) |
| 3 | HomeLab | **Local volume directories**: `k8s_local_volumes` on rpi-03 creates `/mnt/nvme/k8s/<name>` with owner and mode (`postgres`, `postgres-dumps`, `prometheus`, `grafana`). Updates the `k8s_data_taint_enabled` comment | — | [HomeLab #42](https://github.com/GreenMachine582/HomeLab/pull/42) |
| 4 | both | **Postgres**: StatefulSet, PV and PVC, Service, superuser secret, per-app database Job, `pg_dump` CronJob, `homelab-critical` PriorityClass. HomeLab: `pg_dump_fetch.yml` copies dumps home. Restore rehearsal documented | 3 | [#36](https://github.com/GreenMachine582/homelab-cluster/pull/36) + [HomeLab #44](https://github.com/GreenMachine582/HomeLab/pull/44) |
| 5 | homelab-cluster | **Authentik**: HelmRepository + HelmRelease on external Postgres, `HTTPRoute` on `auth.home`, SOPS secrets; namespace added to the `homelab-deploys` alert | 4 | [#38](https://github.com/GreenMachine582/homelab-cluster/pull/38); blueprints [#40](https://github.com/GreenMachine582/homelab-cluster/pull/40), [#41](https://github.com/GreenMachine582/homelab-cluster/pull/41), [#42](https://github.com/GreenMachine582/homelab-cluster/pull/42), [#43](https://github.com/GreenMachine582/homelab-cluster/pull/43) |
| 6 | homelab-cluster | **Monitoring + Grafana**: slimmed `kube-prometheus-stack`, Prometheus and Grafana PVs, Alertmanager → `#homelab-alerts`, Grafana on `grafana.home` with Authentik OIDC | 3, 5; `#homelab-alerts` webhook. The Grafana application comes from a blueprint | [#44](https://github.com/GreenMachine582/homelab-cluster/pull/44); login fixes [#46](https://github.com/GreenMachine582/homelab-cluster/pull/46), auto-login [#48](https://github.com/GreenMachine582/homelab-cluster/pull/48) |
| 7 | both | **Exit + docs**: crash-loop and failed-Job alert tests and a dump restore, as repeatable HomeLab playbooks (`alert_test.yml`, `pg_restore_test.yml`); M5 marked done | 1–6 | [HomeLab #45](https://github.com/GreenMachine582/HomeLab/pull/45) + [#49](https://github.com/GreenMachine582/homelab-cluster/pull/49) |

Order: 1 and 3 can start in any order. 2 needs 1. Then 4 → 5 → 6 → 7.

## Postgres runbook

`apps/base/postgres/`: Postgres 18 at `postgres.postgres.svc:5432`, data on `/mnt/nvme/k8s/postgres` (rpi-03).
Only `authentik` and this namespace's own jobs can connect (`networkpolicy.yaml`, M5.5).

- **Adding an app:** add a key named after the app (lowercase, digits, `_`) to `postgres-app-passwords`
  ([SECRETS.md](SECRETS.md#-postgres-app-passwords)), then bump `homelab/run` in `app-databases-job.yaml`. Flux
  replaces the Job, which creates the role and database. Give the app its own copy of the password in its namespace. Add its namespace to `allow-clients` in
  `networkpolicy.yaml`, or its connections are dropped.
- **Check it:**
  ```bash
  kubectl -n postgres get pod,pvc                        # postgres-0 Running, both claims Bound
  kubectl -n postgres logs job/app-databases             # "ready: <app>" per app
  kubectl -n postgres exec postgres-0 -- psql -U postgres -c '\l'
  ```
- **Test a dump:** `kubectl -n postgres create job --from=cronjob/pg-dump dump-test`, then
  `kubectl -n postgres logs job/dump-test` lists `/dumps`. HomeLab's `pg_dump_fetch.yml` copies the newest home.
- **Copy to the backup drive:** `pg-dump-offnode` (03:15) copies the newest dump to the backup drive on rpi-02
  (`postgres-dumps-offnode`, NFS) and keeps 30 there. Test it with
  `kubectl -n postgres create job --from=cronjob/pg-dump-offnode offnode-test`, then
  `kubectl -n postgres logs job/offnode-test` lists the drive's dumps. Clean up with
  `kubectl -n postgres delete job offnode-test`.
  When the drive is down, the pod waits on the mount until the 30-minute deadline and the Job fails, so
  `KubeJobFailed` alerts. `pg-dump` itself still runs. Set up in HomeLab `docs/K8S_CLUSTER.md` › Backup drive.
- **PV recovery:** the PVs are `Retain` and each has a `claimRef`. After a cluster rebuild, or if a PVC was deleted,
  the data is still on rpi-03. Delete the old PV object if it's `Released` (`kubectl delete pv postgres-data`), and
  Flux recreates it from git, already bound to its claim. Never delete `/mnt/nvme/k8s/postgres` itself.
- **Restore rehearsal:** HomeLab `ansible-playbook playbooks/pg_restore_test.yml` (after `pg_dump_fetch.yml`) loads
  the newest fetched dump into a throwaway pod and checks the databases match the live ones. Run it after Postgres
  upgrades. By hand, a real restore is `zcat pg_dumpall-*.sql.gz | psql -U postgres` into an empty instance.
- **Major upgrades** (19+): Renovate's cap keeps them out. Dump, restore into a new major on a fresh PV, and switch
  over in a PR.

## Authentik blueprints

Authentik's config lives in `apps/base/authentik/blueprints/`: MFA required, the brand and outpost host,
`homelab-admins`, and the Grafana app with its `grafana-users` access group. A blueprint change restarts the worker,
which applies them. [AUTHENTIK.md](AUTHENTIK.md) has the files, how changes apply, the access model (a
`<slug>-users` group per application, plus `homelab-admins`), and how to add an application.

## Monitoring runbook

`apps/base/monitoring/`: kube-prometheus-stack in `monitoring`. Prometheus (7 days, 9 GB cap) and Grafana keep their
data on rpi-03 (`/mnt/nvme/k8s/prometheus`, `/mnt/nvme/k8s/grafana`). Alertmanager has no PV, so silences don't
survive a restart.

- **Grafana:** `https://grafana.home.green-tech-hub.com` goes straight to Authentik; there's no Grafana login page.
  Who gets in is decided in Authentik (`homelab-admins` or `grafana-users`,
  [AUTHENTIK.md › Access](AUTHENTIK.md#-access)). `homelab-admins` are Grafana Admins; everyone else is a Viewer.
  Signing out of Grafana signs you out of Authentik too. The local `admin` is break-glass, for when Authentik is down
  ([below](#-grafana-break-glass-login)).
- **Check it:**
  ```bash
  flux get hr -n monitoring                         # kube-prometheus-stack Ready
  kubectl -n monitoring get pod,pvc                 # all Running; both claims Bound
  kubectl -n monitoring port-forward svc/kps-prometheus 9090   # http://localhost:9090/targets
  ```
  Every target should be up. etcd, the scheduler, the controller-manager and kube-proxy aren't scraped (see
  Decisions).
- **Alerts:** the chart's default rules, minus those for unscraped components, go to Discord `#homelab-alerts`,
  grouped by alert and namespace and repeated every 12 h while firing. `Watchdog` (always firing) is dropped.
- **Test the Discord path:**
  ```bash
  kubectl -n monitoring exec alertmanager-kps-alertmanager-0 -c alertmanager -- \
    amtool alert add homelab_test severity=warning --annotation=summary="Test alert" \
    --alertmanager.url=http://localhost:9093
  ```
  It posts within about 30 s, and posts *resolved* about 5 minutes later.
- **Test real alerts:** HomeLab `ansible-playbook playbooks/alert_test.yml` breaks a pod and a `pg_dump` Job on
  purpose and waits for KubePodCrashLooping and KubeJobFailed (about 20 minutes). Run it after kube-prometheus-stack
  or Alertmanager changes.
- **A failed Job keeps alerting** (every 12 h) until it's deleted: `kubectl -n <ns> delete job <name>`.

> [!NOTE]
> **Info alerts post only alongside a warning.** The chart's `InfoInhibitor` rule holds back *info* alerts, such as
> CPUThrottlingHigh, unless a warning fires in the same namespace. So an info alert you've never seen may show up
> next to an unrelated warning. The alert test surfaced Postgres CPU throttling this way.
- **Silence something:** Grafana → Alerting → Silences (Alertmanager datasource), or `amtool silence add` from the
  same pod.

### 🆘 Grafana break-glass login

For when Authentik is down, or a Grafana OIDC change locks everyone out.

<details>
<summary><b>Sign in as the local <code>admin</code></b></summary>

1. Open `https://grafana.home.green-tech-hub.com/login?disableAutoLogin=true`. It shows Grafana's own
   username/password form instead of redirecting to Authentik.
2. Username `admin`. The password:
   ```bash
   kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
   ```
   Or from git, with the private key: [SECRETS.md › Grafana admin](SECRETS.md#-grafana-admin).

> [!TIP]
> The bypass URL works while `auto_login` is on; there's nothing to turn off first. Bookmark it next to the
> password.

</details>

## What's needed from you

1. **A Discord `#homelab-alerts` channel and webhook**, then the PR 6 secrets. In WSL, from the OneDrive clone on the
   PR's branch:
   ```bash
   scripts/sops-secret.sh apps/prod/monitoring/alertmanager-discord.sops.yaml alertmanager-discord monitoring url=ask
   scripts/sops-secret.sh apps/prod/monitoring/grafana-oidc.sops.yaml grafana-oidc monitoring \
     GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=sops:apps/prod/authentik/authentik-grafana-oidc.sops.yaml:AUTHENTIK_GRAFANA_CLIENT_SECRET
   scripts/sops-secret.sh apps/prod/monitoring/grafana-admin.sops.yaml grafana-admin monitoring \
     admin-user=ask admin-password=gen:40      # type admin at the prompt
   ```
   Details in [SECRETS.md](SECRETS.md).
2. ~~**Make the GHCR package public** after its first push (GitHub → Packages → `greentechhub-ui-playground` →
   Package settings → Change visibility).~~ Done: the image pulls without credentials.
3. **Authentik first login** after PR 5:
   1. Go to `https://auth.home.green-tech-hub.com/` and log in as `akadmin` with the bootstrap password from
      `authentik-secrets`, which you typed in and keep in your password manager.
   2. **Enroll MFA** when prompted. The `mfa` blueprint makes it required for every user without a device. To add
      more devices later: the user interface (`/if/user/`) → Settings → MFA Devices → Enroll.
   3. Create your own user (Admin interface → Directory → Users), add it to the **`homelab-admins`** group, and log in
      as it. Keep `akadmin` as break-glass.
   4. The Grafana provider and application come from the `grafana` blueprint, so there's nothing to click. Add
      anyone else who should use Grafana to `grafana-users` ([AUTHENTIK.md › Access](AUTHENTIK.md#-access)).

## Things to watch

- **Dumps off-site:** `pg-dump-offnode` copies each dump to the backup drive on rpi-02 (since 28 Oct), but that drive
  is at the site too. The copy fetched home with `pg_dump_fetch.yml` is still the only off-site one, so keep fetching.
- **Fetching dumps needs the site route:** `pg_dump_fetch.yml` timed out waiting for sudo on rpi-03 until the
  laptop-01 subnet route was approved in Tailscale. Approve it before fetching.
- **rpi-03 holds all state:** Postgres, its dumps, Prometheus and Grafana. If rpi-03 is down, so are Authentik,
  Grafana and anything with a database, and public access too (cloudflared runs there).
- **Public playground off:** the persona switcher lets anyone act as an admin of the demo. Keep it off the tunnel
  until it's behind Authentik. The cluster has no network policies yet, so an exposed pod could reach every other
  pod. CI's `public-guard` now blocks a tunnel rule to any namespace without them.
- **No control-plane metrics:** etcd, scheduler and controller-manager problems won't alert. HomeLab's etcd snapshot
  failures still go to Discord.
- **Monitoring inside the cluster:** nothing alerts if the whole site goes quiet. That's the external Uptime Kuma's
  job (backlog, priority).
