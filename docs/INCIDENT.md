# 🚨 Incident runbook

What to do when something public is misbehaving or may be compromised: cut it off, lock people out, rotate what
leaked, then look at what happened. Written for M5.5, before the playground and `auth` go public. Commands run from
dev-wsl with the admin kubeconfig.

**Quick links:** [✂️ Kill switch](#️-kill-switch) · [👤 Users and sessions](#-users-and-sessions) ·
[🔄 Rotate](#-rotate) · [🔎 Afterwards](#-afterwards)

> [!IMPORTANT]
> **Cut first, investigate second.** Every step here is easy to undo. A public app left up while you work out
> what's wrong isn't.

---

## ✂️ Kill switch

Pick the smallest cut that stops it.

| Cut | How | Takes effect | Undo |
|---|---|---|---|
| **One host, now** | Cloudflare → DNS → Records → delete the host's CNAME | Within a minute or so | `cloudflared tunnel route dns homelab <host>` |
| **One host, for good** | PR: delete its rule in `infrastructure/configs/cloudflared/configmap.yaml` and bump `homelab/config-rev` | When Flux applies it | Revert the PR |
| **Everything public** | Suspend Flux's `infrastructure-configs`, then scale cloudflared to 0 (below) | Immediately | Resume (below) |

<details open>
<summary><b>Everything public: scale cloudflared to 0</b></summary>

Suspend first, or Flux scales it back up at its next reconcile (every 10 minutes):

```bash
flux suspend kustomization infrastructure-configs
kubectl -n cloudflared scale deploy cloudflared --replicas=0
kubectl -n cloudflared get pods                 # none left
```

The tunnel shows **Down** in Cloudflare → Zero Trust → Networks → Tunnels, and every public host returns a
Cloudflare 1033/530 error. LAN names (`*.home`) don't use the tunnel, so they keep working.

While it's suspended, Flux applies nothing in `infrastructure/configs`. `apps` still reconciles. Resume when it's safe:

```bash
flux resume kustomization infrastructure-configs   # scales cloudflared back to git's replica count
kubectl -n cloudflared rollout status deploy cloudflared
```

</details>

> [!NOTE]
> **Last tested:** not yet. Run the scale-to-0 drill once before the first M5.5 host goes public, then record the
> date here.

---

## 👤 Users and sessions

In Authentik's admin interface (`https://auth.home.green-tech-hub.com/if/admin/`, LAN only).

- **Lock one user out:** Directory → Users → the user → **Deactivate**. Then open their **Sessions** tab and delete
  every session. A deactivated user can't sign in, and deleting the sessions signs them out.
- **Sign everyone out:**
  ```bash
  kubectl -n authentik exec deploy/authentik-worker -- ak shell -c \
    "from authentik.core.models import AuthenticatedSession; print(AuthenticatedSession.objects.all().delete())"
  ```
- **Apps keep their own sessions.** Signing out of Authentik doesn't end a session an app already holds. In
  Grafana, revoke them under Administration → Users → the user → Sessions. Other apps behind the M5.5 proxy
  provider are covered, because the outpost checks Authentik on every request.
- **Suspected admin compromise:** also deactivate any other `homelab-admins` member you didn't add. Use `akadmin`,
  the break-glass account, only to recover.

---

## 🔄 Rotate

Rotate whatever may have leaked. Each secret's commands are in [SECRETS.md](SECRETS.md).

| Suspect | Rotate |
|---|---|
| Tunnel credentials (anyone could run a connector for `homelab`) | [SECRETS.md › cloudflared tunnel credentials](SECRETS.md#-cloudflared-tunnel-credentials) › Rotate: a new tunnel, DNS moved with `--overwrite-dns`, then the old one deleted |
| Authentik itself | `AUTHENTIK_SECRET_KEY` and the bootstrap password ([SECRETS.md › Authentik secrets](SECRETS.md#-authentik-secrets)). A new secret key signs everyone out |
| An app's OIDC client | Its client secret, in both copies (Authentik's and the app's) |
| A database password | The app's key in `postgres-app-passwords`, and the app's copy ([Postgres runbook](M5_WORKLOADS.md#postgres-runbook)) |
| `~/.cloudflared/cert.pem` | It's account-level. Delete it in WSL, delete any token you don't recognise under Cloudflare → My Profile → API Tokens, and check Zero Trust → Tunnels for tunnels you didn't create. Run `cloudflared tunnel login` again when you next need it |

---

## 🔎 Afterwards

1. **Authentik events:** Admin → Events → Logs. Filter on the user, or on `login_failed`, `suspicious_request` and
   `model_updated`.
2. **cloudflared:** `kubectl -n cloudflared logs deploy/cloudflared --since=24h` shows which hosts were hit.
3. **The app:** `kubectl -n <ns> logs deploy/<name> --since=24h`. There's no log store yet (Loki is in the backlog),
   so a restarted pod has already lost its logs.
4. **Cloudflare:** Security → Events shows what the WAF, the rate limit and Bot Fight Mode blocked.
5. **Network:** once the M5.5 network policies land, the Hubble CLI's `hubble observe --verdict DROPPED -n <ns>`
   shows what a pod tried to reach.

Then write a short note in the PR that fixes it:
- what happened and when
- how it was found
- what was cut and rotated
- what changes so it can't happen again

> [!TIP]
> Go public again only through a PR that passes `public-guard`, as in
> [ADDING_A_SERVICE.md › Before going public](ADDING_A_SERVICE.md#-before-going-public).
