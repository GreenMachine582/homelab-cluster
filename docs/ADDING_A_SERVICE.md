# 🧩 Adding a service

How to put an app on the cluster behind the shared Gateway, on the LAN and optionally in public. The worked
example is `whoami` (`apps/base/whoami`), live at `https://whoami.home.green-tech-hub.com`. It was public too until
M5.5 took it off the tunnel; it comes back once it's hardened. Replace `<name>` with the service's name throughout.

**Quick links:** [📁 Layout](#-1-layout) · [🏗️ Deployment](#️-2-deployment) · [🌐 Route](#-3-service-and-httproute) ·
[🔐 Secrets](#-4-secrets) · [💾 Storage](#-5-storage) · [☁️ Public](#️-6-public-access-optional) ·
[🚀 Ship](#-7-ship-and-verify) · [🗑️ Remove](#️-8-removing-a-service) · [🩺 Troubleshooting](#-troubleshooting)

> [!TIP]
> **Already done for you:**
> - 🌍 **DNS:** the Cloudflare record `*.home.green-tech-hub.com` → `192.168.50.240` covers every LAN name.
> - 🔒 **TLS:** the Gateway's wildcard certificate for `*.home.green-tech-hub.com` (production Let's Encrypt).
> - ↪️ **HTTP → HTTPS:** a redirect on the Gateway.
> - 💬 **Deploy notifications:** Discord `#homelab-deploys`.

### ✅ Checklist

- [ ] `apps/base/<name>/` with namespace, deployment, service, httproute and kustomization
- [ ] `apps/prod/<name>/` overlay, listed in `apps/prod/kustomization.yaml`
- [ ] Secrets as `*.sops.yaml`, each with an entry in [SECRETS.md](SECRETS.md)
- [ ] *(optional)* public: [Before going public](#-before-going-public) done, then tunnel rule + `config-rev` bump +
  `tunnel route dns` + a Cloudflare setup row
- [ ] `kubectl kustomize apps/prod` renders, then PR → merge → check

---

## 📁 1. Layout

```
apps/
  base/<name>/
    kustomization.yaml     # lists the files below
    namespace.yaml         # namespace = <name>, one per service
    deployment.yaml
    service.yaml
    httproute.yaml
  prod/
    kustomization.yaml     # add "- <name>" under resources
    <name>/
      kustomization.yaml   # resources: [../../base/<name>], plus any *.sops.yaml
```

<details>
<summary><code>apps/prod/&lt;name&gt;/kustomization.yaml</code></summary>

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/<name>
```

</details>

The `apps` Flux Kustomization applies `apps/prod` with SOPS decryption, after `infrastructure` and
`infrastructure-configs` are Ready. It prunes, so deleting a folder removes the service.

---

## 🏗️ 2. Deployment

The rules (from [CONTRIBUTING.md](../CONTRIBUTING.md)):
- 📦 **Image:** multi-arch (amd64 + arm64), pinned to an exact tag. The workers are Pis.
- 📏 **Resources:** requests and a memory limit.
- 🛡️ **Hardening:** non-root, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, drop ALL
  capabilities, `seccompProfile: RuntimeDefault`. Mount an `emptyDir` for any path the app must write.
- 📍 **Placement:** anything behind the Gateway sets `nodeSelector: homelab/l7-proxy: supported`. The Gateway's
  Envoy only runs on those nodes (the Pi 4 kernels can't run it). Today that means rpi-03, because laptop-01 is tainted.

<details>
<summary>Example: <code>apps/base/whoami/deployment.yaml</code> (pod spec)</summary>

```yaml
    spec:
      nodeSelector:
        homelab/l7-proxy: supported
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: whoami
          image: traefik/whoami:v1.11.0
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /health
              port: http
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          resources:
            requests: { cpu: 5m, memory: 16Mi }
            limits: { memory: 32Mi }
```

</details>

---

## 🌐 3. Service and HTTPRoute

A plain ClusterIP Service, plus an HTTPRoute attached to the shared Gateway's **https** listener.

<details open>
<summary><code>apps/base/&lt;name&gt;/httproute.yaml</code></summary>

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <name>
  namespace: <name>
spec:
  parentRefs:
    - name: homelab
      namespace: gateway
      sectionName: https
  hostnames:
    - <name>.home.green-tech-hub.com
  rules:
    - backendRefs:
        - name: <name>
          port: 80
```

</details>

> [!NOTE]
> Don't attach to the `http` listener. It only accepts routes from the `gateway` namespace, and redirects everything
> to HTTPS.

> [!TIP]
> If the service has a login, sign in through Authentik instead of local accounts. Follow
> [AUTHENTIK.md › Adding an application](AUTHENTIK.md#-adding-an-application): a blueprint, a `<slug>-users`
> access group, and a client secret.

---

## 🔐 4. Secrets

1. Put each Secret in `apps/prod/<name>/<secret>.sops.yaml` and list it in that overlay's `kustomization.yaml`.
2. Encrypt it through a pipe, never via a plaintext file. See [SECRETS.md › Recreating a secret](SECRETS.md#️-recreating-a-secret).
3. In the same PR, add an entry to the [SECRETS.md inventory](SECRETS.md#-inventory): what it holds, where the value
   comes from, and the commands.

---

## 💾 5. Storage

For stateful services, use the `local-nvme` StorageClass (`infrastructure/configs/storage/local-nvme.yaml`). It has
no provisioner, so each workload brings its own PersistentVolume:
- the path is under `/mnt/nvme/k8s/<name>` on rpi-03
- it has node affinity to rpi-03
- reclaim policy `Retain`

The PVC asks for `storageClassName: local-nvme` by name.

---

## ☁️ 6. Public access (optional)

Anything public is reachable by anyone, so it's hardened before it gets a tunnel rule.

### 🛑 Before going public

**Enforced by CI.** The `public-guard` check (`scripts/public-guard.py`) follows every tunnel hostname to its
HTTPRoute, and to any backend in another namespace. It fails the PR unless each of those namespaces has:
- [ ] the label `pod-security.kubernetes.io/enforce: restricted` on its Namespace
- [ ] a default-deny `CiliumNetworkPolicy` (`endpointSelector: {}`, with ingress and egress rules), plus policies
  allowing only the traffic the app needs. Copy `apps/base/gth-playground/networkpolicy.yaml`: default deny, DNS,
  and ingress from the Gateway only. Rules stay L3/L4, because the Pi 4s have no L7 proxy
- [ ] `automountServiceAccountToken: false` on every pod spec
- [ ] the [hardening](#️-2-deployment) on every container: non-root, `RuntimeDefault` seccomp, no privilege
  escalation, read-only root filesystem, ALL capabilities dropped
- [ ] CPU and memory requests and a memory limit on every container

Run it before pushing:
```bash
kubectl kustomize apps/prod > /tmp/apps.yaml && kubectl kustomize infrastructure/configs > /tmp/infra.yaml
python3 scripts/public-guard.py /tmp/apps.yaml /tmp/infra.yaml
```

> [!WARNING]
> CI only sees manifests in git. Workloads a HelmRelease renders only get a warning, so check them in the cluster:
> `kubectl -n <name> get pods -o yaml | grep -E 'automount|runAsNonRoot|readOnlyRoot|allowPrivilege'`.

**Checked by you, in the PR:**
- [ ] **Login and admin UIs are behind Authentik.** Use the app's OIDC, or Authentik's proxy provider if it has none.
  An app that lets visitors change shared state (like the playground's persona switcher) is never public without it.
- [ ] **Security headers** on the public route: HSTS, `X-Content-Type-Options: nosniff`,
  `Referrer-Policy`, `X-Frame-Options: DENY`.
- [ ] **No unreviewed automerge.** The app's image and chart get no Renovate `automerge` rule, so every update to a
  public app is reviewed.
- [ ] **An explicit DNS record** for the host. Never a wildcard CNAME to the tunnel.
- [ ] The Cloudflare [edge settings](CLOUDFLARE.md#-cloudflare-edge-settings) are still in place.
- [ ] You know how to cut it off: [INCIDENT.md › Kill switch](INCIDENT.md#️-kill-switch).

### Publishing

The tunnel sends `<name>.green-tech-hub.com` to the Gateway as `<name>.home.green-tech-hub.com`. The LAN route and
certificate serve it, and nothing on the Gateway changes.

1. Add a rule to `infrastructure/configs/cloudflared/configmap.yaml`, **above** the `http_status:404` catch-all:
   ```yaml
      - hostname: <name>.green-tech-hub.com
        service: https://cilium-gateway-homelab.gateway.svc.cluster.local:443
        originRequest:
          originServerName: <name>.home.green-tech-hub.com
          httpHostHeader: <name>.home.green-tech-hub.com
   ```
2. Bump `homelab/config-rev` in `infrastructure/configs/cloudflared/deployment.yaml`. That makes the pod restart and
   load the new config.
   - Allow cloudflared to reach the backend: add its namespace, labels and container port to `allow-backends` in
     `infrastructure/configs/cloudflared/networkpolicy.yaml`. Without it, the Gateway answers 403. Cilium's Envoy
     checks cloudflared's egress policy against the backend too.
3. In WSL, create the DNS record. It's a proxied CNAME to the tunnel:
   ```bash
   cloudflared tunnel route dns homelab <name>.green-tech-hub.com
   ```
4. Add the record to the [Cloudflare setup](CLOUDFLARE.md#-cloudflare-setup-manual) table.

> [!NOTE]
> Until M5.5 adds the public Gateway listener, public names are rewritten to their `.home` name, so the guard
> follows `httpHostHeader` to the route. After that, each rule keeps its public Host and the route lists it.

---

## 🚀 7. Ship and verify

1. 🧪 Render it: `kubectl kustomize apps/prod`. Then open a PR as in [CONTRIBUTING.md](../CONTRIBUTING.md), and merge.
2. 💬 Discord `#homelab-deploys` shows the commit being pulled, then what `apps` (and `infrastructure-configs`, if you
   published it) applied, or the error.
3. 🔎 Check:
   ```bash
   kubectl -n <name> get pods,svc,httproute
   kubectl -n <name> get httproute <name> -o jsonpath='{.status.parents[0].conditions}'   # Accepted, ResolvedRefs True
   curl -sI https://<name>.home.green-tech-hub.com     # LAN
   curl -sI https://<name>.green-tech-hub.com          # public, if published
   ```

> [!NOTE]
> From home, the LAN check needs laptop-01's subnet route approved in the Tailscale console. Disable it again
> afterwards.

---

## 🗑️ 8. Removing a service

1. Delete `apps/base/<name>/`, `apps/prod/<name>/` and its line in `apps/prod/kustomization.yaml`. Flux prunes the
   namespace and everything in it.
2. If it was public:
   1. Delete its tunnel rule and bump `config-rev`.
   2. Delete the CNAME in the Cloudflare dashboard.
   3. Delete its row in the Cloudflare setup table.
3. Remove its entries from [SECRETS.md](SECRETS.md).

> [!CAUTION]
> PVs with `Retain` stay behind, and so does their data on rpi-03. Delete them by hand once you're sure.

---

## 🩺 Troubleshooting

<details>
<summary><b>Symptom → likely cause</b></summary>

| Symptom | Likely cause |
|---|---|
| HTTPRoute `Accepted: False` | Wrong `parentRefs` (name `homelab`, namespace `gateway`, sectionName `https`), or attached to `http` |
| HTTPRoute `ResolvedRefs: False` | The Service name or port in `backendRefs` doesn't exist |
| 404 from the Gateway | The hostname isn't `<name>.home.green-tech-hub.com`, or the route isn't accepted |
| 503 from the Gateway | No ready backend pods |
| LAN request times out | From home: laptop-01's subnet route isn't approved. `cluster_status.yml` says so |
| Public 502 | The tunnel reached Cloudflare but not the service. Check the rule's names, and that the backend pods run on an `l7-proxy=supported` node |
| Public 530 / 1033 | No tunnel connector. Check `kubectl -n cloudflared get pods` and their logs |
| Public 404 from Cloudflare | The tunnel has no rule for the hostname (check the rule order, and `config-rev` bumped) |
| Public 403 from the Gateway | cloudflared's `allow-backends` policy doesn't list the backend (§6 step 2) |
| `public-guard` fails | Each error names the host, namespace and missing control. "No HTTPRoute serves" means the rule's `httpHostHeader` (or hostname) matches no route's `hostnames` |

</details>
