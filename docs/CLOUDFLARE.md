# ☁️ Cloudflare

Everything on the Cloudflare side of the cluster: what was set up by hand in the dashboard (enough to rebuild it),
the zone's edge settings, and how the tunnel runs. Tunnel ingress rules themselves are in git
(`infrastructure/configs/cloudflared/configmap.yaml`); publishing a service is
[ADDING_A_SERVICE.md](ADDING_A_SERVICE.md) §6.

**Quick links:** [📋 Setup](#-cloudflare-setup-manual) · [🔒 Edge settings](#-cloudflare-edge-settings) ·
[🚇 Tunnel](#-tunnel)

---

## 📋 Cloudflare setup (manual)

Everything on the Cloudflare side that isn't in git, enough to rebuild it from scratch. Zone: `green-tech-hub.com`.
Update this table whenever the dashboard changes.

| What | Where in the dashboard | Value | Used by |
|---|---|---|---|
| API token | My Profile → API Tokens | Custom token: Zone · DNS · Edit and Zone · Zone · Read, zone `green-tech-hub.com` only. Recreate: [SECRETS.md](SECRETS.md) | cert-manager DNS-01 |
| LAN wildcard record | green-tech-hub.com → DNS → Records | Type `A`, name `*.home`, IPv4 `192.168.50.240` (the Gateway, `infrastructure/configs/gateway/gateway.yaml`), **DNS only** (grey cloud), TTL Auto | Every `*.home.green-tech-hub.com` service |
| Apex record + tunnel route | DNS → Records; Zero Trust → Networks → Tunnels | Pre-existing, proxied apex `green-tech-hub.com` routed through a tunnel to `https://localhost:8080`. Not managed by this repo | Outside the cluster |
| `homelab` tunnel | Zero Trust → Networks → Tunnels | Locally managed (the dashboard shows it but its ingress rules live in `infrastructure/configs/cloudflared/configmap.yaml`). ID `0906ae8b-a6d6-49d7-80f4-6bc4d724fcca`. Created in WSL with `cloudflared tunnel login` (writes `~/.cloudflared/cert.pem`, pick `green-tech-hub.com`) then `cloudflared tunnel create homelab`. Credentials: [SECRETS.md](SECRETS.md) | cloudflared |
| ~~Public `whoami` record~~ | DNS → Records | **Deleted in M5.5 PR 1** with its tunnel rule; whoami wasn't hardened. It comes back in M5.5 PR 3 as the public listener's test. Was: `CNAME` `whoami` → `0906ae8b-a6d6-49d7-80f4-6bc4d724fcca.cfargotunnel.com`, proxied, from `cloudflared tunnel route dns homelab whoami.green-tech-hub.com` | Public whoami |

Notes:
- The A record must stay **DNS only**. Proxied, Cloudflare would answer with its own IPs and couldn't reach a
  private address anyway.
- If the Gateway IP changes (`gateway.yaml` `spec.addresses`), change the record too.
- Certificate renewals are unaffected: DNS-01 writes TXT records at `_acme-challenge.home`, which the wildcard A
  doesn't shadow.
- Check it: `nslookup whoami.home.green-tech-hub.com 1.1.1.1` and the same against the local resolver should
  both give `192.168.50.240`. If only the local resolver returns nothing, it's dropping private-IP answers
  (DNS-rebind protection). The home ASUS router doesn't (checked 21 Oct 2026).

---

## 🔒 Cloudflare edge settings

The zone-wide settings every public host relies on (M5.5, decision 43). Check them before each new public host, and
tick them here with the date once they're set.

| Done | Setting | Where in the dashboard | Value |
|---|---|---|---|
| ☐ | Encryption mode | SSL/TLS → Overview | **Full (strict)** |
| ☐ | Minimum TLS version | SSL/TLS → Edge Certificates | **TLS 1.2** |
| ☐ | Always Use HTTPS | SSL/TLS → Edge Certificates | **On** |
| ☐ | HSTS | SSL/TLS → Edge Certificates → HSTS | On, max-age 6 months to start, `includeSubDomains` **off** (the pre-existing apex isn't covered by this repo) |
| ☐ | Bot Fight Mode | Security → Bots | **On** |
| ☐ | DNS records | DNS → Records | One explicit proxied CNAME per public host. **No wildcard** pointing at the tunnel |

> [!NOTE]
> Full (strict) is zone-wide, and it sets how Cloudflare connects to an origin. Tunnelled hosts, including the
> pre-existing apex, reach their origin through cloudflared, which does its own TLS (`originServerName`), so they
> shouldn't be affected. Check the apex still loads after switching anyway.

**Publishing or removing a service:** see [ADDING_A_SERVICE.md](ADDING_A_SERVICE.md) §6 and §8. Add every record
created there to the table above.

---

## 🚇 Tunnel

- **Placement:** cloudflared must run on an Envoy node to reach the Gateway, so its one replica sits on rpi-03
  (`homelab/l7-proxy: supported`). If rpi-03 is down, public access is down. Go back to 2 replicas when another
  Envoy node can take one.
- **Protocol:** the site network drops outbound UDP 7844, so QUIC fails. The tunnel is pinned to `protocol: http2`
  over TCP 7844, which cloudflared's own pre-check also recommends. If the site firewall ever allows UDP 7844, the
  pin can go.
- **Config changes:** bump `homelab/config-rev` in `deployment.yaml` with every ConfigMap change; kustomize doesn't
  hash it, so the pod wouldn't restart otherwise.
- **Cutting it off:** [INCIDENT.md › Kill switch](INCIDENT.md#️-kill-switch).
