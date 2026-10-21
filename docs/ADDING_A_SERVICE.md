# Adding a service

How to put an app on the cluster behind the shared Gateway, on the LAN and optionally in public. The worked
example is `whoami` (`apps/base/whoami`), which is live at `https://whoami.home.green-tech-hub.com` and
`https://whoami.green-tech-hub.com`. Replace `<name>` with the service's name throughout.

What you get for free:
- **DNS:** the Cloudflare record `*.home.green-tech-hub.com` → `192.168.50.240` covers every LAN name.
- **TLS:** the Gateway's wildcard certificate for `*.home.green-tech-hub.com` (production Let's Encrypt).
- **HTTP → HTTPS:** a redirect on the Gateway.
- **Deploy notifications:** Discord `#homelab-deploys`.

## 1. Layout

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

`apps/prod/<name>/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/<name>
```

The `apps` Flux Kustomization applies `apps/prod` with SOPS decryption, after `infrastructure` and
`infrastructure-configs` are Ready. It prunes, so deleting a folder removes the service.

## 2. Deployment

The rules (from [CONTRIBUTING.md](../CONTRIBUTING.md)):
- **Image:** multi-arch (amd64 + arm64), pinned to an exact tag. The workers are Pis.
- **Resources:** requests and a memory limit.
- **Hardening:** non-root, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, drop ALL capabilities,
  `seccompProfile: RuntimeDefault`. Mount an `emptyDir` for any path the app must write.
- **Placement:** anything behind the Gateway sets `nodeSelector: homelab/l7-proxy: supported`. The Gateway's Envoy
  only runs on those nodes (the Pi 4 kernels can't run it). Today that means rpi-03, because laptop-01 is tainted.

From `apps/base/whoami/deployment.yaml`:

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

## 3. Service and HTTPRoute

A plain ClusterIP Service, plus an HTTPRoute attached to the shared Gateway's **https** listener:

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

Don't attach to the `http` listener. It only accepts routes from the `gateway` namespace, and redirects everything
to HTTPS.

## 4. Secrets

Put each Secret in `apps/prod/<name>/<secret>.sops.yaml`, list it in that overlay's `kustomization.yaml`, and
encrypt it through a pipe, never via a plaintext file. Follow [SECRETS.md](SECRETS.md) ("Recreating a secret"),
and add an entry there in the same PR: what it holds, where the value comes from, and the commands.

## 5. Storage (stateful services)

Use the `local-nvme` StorageClass (`infrastructure/configs/storage/local-nvme.yaml`). It has no provisioner, so each
workload brings its own PersistentVolume:
- the path is under `/mnt/nvme/k8s/<name>` on rpi-03
- it has node affinity to rpi-03
- reclaim policy `Retain`

The PVC asks for `storageClassName: local-nvme` by name.

## 6. Public access (optional)

The tunnel sends `<name>.green-tech-hub.com` to the Gateway as `<name>.home.green-tech-hub.com`. The LAN
route and certificate serve it, and nothing on the Gateway changes.

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
3. Create the DNS record in WSL. It's a proxied CNAME to the tunnel:
   ```bash
   cloudflared tunnel route dns homelab <name>.green-tech-hub.com
   ```
4. Add the record to the [Cloudflare setup](M4_PLATFORM.md#cloudflare-setup-manual) table.

Think before publishing: anything public is reachable by anyone. Put admin UIs behind Cloudflare Access, or keep
them LAN-only.

## 7. Ship and verify

1. Render it: `kubectl kustomize apps/prod`. Then open a PR as in [CONTRIBUTING.md](../CONTRIBUTING.md), and merge.
2. Discord `#homelab-deploys` shows the commit being pulled, then what `apps` (and `infrastructure-configs`, if
   you published it) applied, or the error.
3. Check:
   ```bash
   kubectl -n <name> get pods,svc,httproute
   kubectl -n <name> get httproute <name> -o jsonpath='{.status.parents[0].conditions}'   # Accepted, ResolvedRefs True
   curl -sI https://<name>.home.green-tech-hub.com     # LAN
   curl -sI https://<name>.green-tech-hub.com          # public, if published
   ```
   From home, the LAN check needs laptop-01's subnet route approved in the Tailscale console (disable it afterwards).

## 8. Removing a service

1. Delete `apps/base/<name>/` and `apps/prod/<name>/`, and its line in `apps/prod/kustomization.yaml`. Flux prunes
   the namespace and everything in it. PVs with `Retain` and their data on rpi-03 stay; delete them by hand.
2. If it was public, delete its tunnel rule (bump `config-rev`), then delete the CNAME in the Cloudflare dashboard.
   Also delete its row in the Cloudflare setup table.
3. Remove its entries from SECRETS.md.

## Troubleshooting

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
