# 🔐 Secrets

Every SOPS-encrypted file in this repo: what it holds, where the value comes from, and how to recreate it.

> [!IMPORTANT]
> A PR that adds or changes a `*.sops.yaml` updates this file in the same PR.

**Quick links:** [🗝️ How encryption works](#️-how-encryption-works) · [🛠️ Recreating a secret](#️-recreating-a-secret) ·
[📒 Inventory](#-inventory)

---

## 🗝️ How encryption works

- 🔓 **Encrypting** needs only the age **public** key in `.sops.yaml`, so anyone with the repo can recreate a
  secret. Only `data` / `stringData` are encrypted.
- 🔒 **Decrypting or editing** needs the age **private** key at `~/.config/sops/age/keys.txt` in WSL (HomeLab
  `sops_age_key_file`). Flux has its own copy as the `sops-age` secret in `flux-system` (HomeLab
  `playbooks/flux_bootstrap.yml`).

<details>
<summary>⚠️ <b>If the private key is lost</b></summary>

Nothing here can be decrypted any more. To recover:
1. Re-issue every value in the [inventory](#-inventory).
2. Generate a new age key. Put its public key in `.sops.yaml` and in HomeLab's `sops_age_recipient`.
3. Re-run HomeLab's `flux_bootstrap.yml`.
4. Recreate each file.

</details>

---

## 🛠️ Recreating a secret

In WSL, from the root of the **Windows (OneDrive) clone**, on a branch made there. Commits are signed from Windows,
and WSL can't sign.

```bash
cd /mnt/c/Users/Chad/OneDrive/Desktop/Python-Projects/HomeLab/homelab-cluster
scripts/sops-secret.sh <file> <secret-name> <namespace> KEY=SOURCE [KEY=SOURCE...]
```

| SOURCE | Value |
|---|---|
| `gen` / `gen:N` | random, 40 (or N) characters of `A-Za-z0-9` |
| `ask` | typed at a hidden prompt, twice |
| `file:<path>` | a file's contents, e.g. a JSON credentials file |
| `sops:<file>:<key>` | copied from another `*.sops.yaml` (needs the private key) |

The script writes each value only to a private temp directory, removed on exit, and prints just its length. It
encrypts straight into `<file>`, asks before replacing an existing one, and refuses to write the file unless every
value is `ENC[...]`. Each inventory entry below gives its exact command.

> [!TIP]
> To change one value later, run `sops "$f"`. It opens the file decrypted in your editor and re-encrypts it on save
> (needs the private key). To read one value: `sops -d --extract '["data"]["<key>"]' "$f" | base64 -d`.

<details>
<summary>Without the script</summary>

```bash
read -rs VALUE; echo; echo ${#VALUE}        # hidden prompt; prints the length only
kubectl create secret generic <name> -n <namespace> \
  --from-literal=<key>="$VALUE" --dry-run=client -o yaml \
| sops --encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"
unset VALUE
grep -c 'ENC\[' "$f"        # 2 or more: the value plus the sops MAC
```

For a file, use `--from-file=<key>=<path>` instead of `read` + `--from-literal`.

</details>

---

## 📒 Inventory

| | File | Secret (namespace / key) | Used by |
|---|---|---|---|
| ☁️ | [`cloudflare-api-token.sops.yaml`](#️-cloudflare-api-token) | `cert-manager` / `api-token` | cert-manager DNS-01 |
| 🚇 | [`tunnel-credentials.sops.yaml`](#-cloudflared-tunnel-credentials) | `cloudflared` / `credentials.json` | cloudflared |
| 💬 | [`discord-webhook.sops.yaml`](#-discord-webhook) | `flux-system` / `address` | Flux notifications, patch reminder |
| 🐘 | [`postgres-superuser.sops.yaml`](#-postgres-superuser) | `postgres` / `password` | Postgres, `app-databases` Job, `pg-dump` CronJob |
| 🐘 | [`postgres-app-passwords.sops.yaml`](#-postgres-app-passwords) | `postgres` / one key per app (`authentik`) | `app-databases` Job |
| 🔑 | [`authentik-secrets.sops.yaml`](#-authentik-secrets) | `authentik` / `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_POSTGRESQL__PASSWORD`, `AUTHENTIK_BOOTSTRAP_PASSWORD`, `AUTHENTIK_BOOTSTRAP_EMAIL` | Authentik server and worker |
| 📈 | [`authentik-grafana-oidc.sops.yaml`](#-authentik-grafana-oidc-client) | `authentik` / `AUTHENTIK_GRAFANA_CLIENT_SECRET` | the `grafana` blueprint (OAuth2 provider); Grafana's copy in PR 6 |

### ☁️ Cloudflare API token

<details>
<summary><code>infrastructure/configs/cert-manager/cloudflare-api-token.sops.yaml</code></summary>

| | |
|---|---|
| Secret | `cloudflare-api-token` in `cert-manager`, key `api-token` |
| Used by | ClusterIssuers `letsencrypt-staging` and `letsencrypt` (DNS-01) |
| Source | Cloudflare dashboard → My Profile → API Tokens → Create Token → Custom token |
| Scope | Permissions: Zone · DNS · Edit, and Zone · Zone · Read. Zone resources: Include · Specific zone · `green-tech-hub.com`. No client IP filter, no expiry |
| Created | 21 Oct 2026 ([#14](https://github.com/GreenMachine582/homelab-cluster/pull/14)) |

Check the token first (`read -rs VALUE` to hold it without echoing):

```bash
curl -s -H "Authorization: Bearer $VALUE" https://api.cloudflare.com/client/v4/user/tokens/verify
# expect "success":true and "status":"active"
```

Then `unset VALUE` and paste it again at the script's prompt:

```bash
scripts/sops-secret.sh infrastructure/configs/cert-manager/cloudflare-api-token.sops.yaml \
  cloudflare-api-token cert-manager api-token=ask
```

🔄 **Rotate:**
1. Create a new token and recreate the file as above.
2. PR and merge.
3. Wait until `kubectl get clusterissuers` shows both Ready.
4. Delete the old token in Cloudflare.

</details>

### 🚇 cloudflared tunnel credentials

<details>
<summary><code>infrastructure/configs/cloudflared/tunnel-credentials.sops.yaml</code></summary>

| | |
|---|---|
| Secret | `cloudflared-tunnel-credentials` in `cloudflared`, key `credentials.json` |
| Used by | the cloudflared Deployment (the `homelab` tunnel) |
| Source | `cloudflared tunnel create homelab` writes `~/.cloudflared/<TUNNEL_ID>.json` in WSL |
| Needs | the cloudflared CLI (HomeLab `controller.yml -K --tags cloudflared`) and `~/.cloudflared/cert.pem` from `cloudflared tunnel login` |
| Created | 21 Oct 2026 ([#18](https://github.com/GreenMachine582/homelab-cluster/pull/18)) |

It's a file, so this one uses `file:`:

```bash
scripts/sops-secret.sh infrastructure/configs/cloudflared/tunnel-credentials.sops.yaml \
  cloudflared-tunnel-credentials cloudflared credentials.json=file:$HOME/.cloudflared/<TUNNEL_ID>.json
```

🩹 **Lost the JSON?** Regenerate it from the tunnel (needs `cert.pem`), then encrypt it as above:

```bash
cloudflared tunnel token --cred-file "$HOME/.cloudflared/<TUNNEL_ID>.json" homelab
```

🔄 **Rotate** (new tunnel secret). Running `cloudflared tunnel delete homelab` first would break public access until
the new tunnel is up. So instead:
1. Create `homelab2`.
2. Route its hostnames: `cloudflared tunnel route dns --overwrite-dns homelab2 <host>`.
3. In one PR, update `tunnel:` in `configmap.yaml` and this secret.
4. Delete the old tunnel.

> [!CAUTION]
> `~/.cloudflared/cert.pem` is account-level: it can create and delete tunnels and DNS records in the zone. It isn't
> in git. Keep it at mode 600 in WSL, or delete it and run `cloudflared tunnel login` again when needed.

</details>

### 💬 Discord webhook

<details>
<summary><code>infrastructure/configs/flux-notifications/discord-webhook.sops.yaml</code></summary>

| | |
|---|---|
| Secret | `discord-webhook` in `flux-system`, key `address` |
| Used by | Flux Provider `discord`, Alert `homelab-deploys` (deploy notifications); CronJob `patch-reminder` (monthly patching reminder, `patch-reminder.yaml`) |
| Source | Discord: the `#homelab-deploys` channel → Edit Channel → Integrations → Webhooks → New Webhook → Copy Webhook URL |
| Created | 21 Oct 2026 ([#20](https://github.com/GreenMachine582/homelab-cluster/pull/20)) |

```bash
scripts/sops-secret.sh infrastructure/configs/flux-notifications/discord-webhook.sops.yaml \
  discord-webhook flux-system address=ask     # paste the webhook URL
```

🔄 **Rotate:**
1. Delete the webhook in Discord. That revokes it at once.
2. Make a new one.
3. Recreate the file as above.

</details>

### 🐘 Postgres superuser

<details>
<summary><code>apps/prod/postgres/postgres-superuser.sops.yaml</code></summary>

| | |
|---|---|
| Secret | `postgres-superuser` in `postgres`, key `password` |
| Used by | the `postgres` StatefulSet (`POSTGRES_PASSWORD`, applied only on first start of an empty data directory), the `app-databases` Job and the `pg-dump` CronJob |
| Source | generated: `openssl rand`. Nothing outside the cluster knows it |
| Created | 27 Oct 2026 ([#36](https://github.com/GreenMachine582/homelab-cluster/pull/36)) |

Generated, so it's never shown:

```bash
scripts/sops-secret.sh apps/prod/postgres/postgres-superuser.sops.yaml postgres-superuser postgres password=gen
```

🔄 **Rotate.** The image reads `POSTGRES_PASSWORD` only when it creates the database, so a new secret alone doesn't
change the live password:
1. Recreate the file as above, then set the same value in Postgres (read it at a hidden prompt):
   ```bash
   read -rs VALUE; echo
   kubectl -n postgres exec -i postgres-0 -- psql -U postgres -v pass="$VALUE" \
     <<<"SELECT format('ALTER ROLE postgres PASSWORD %L', :'pass') \gexec"
   unset VALUE
   ```
   Inside the pod, local connections are trusted, so this works without the old password.
2. PR and merge. Then check the next `pg-dump` run, or test it with `kubectl -n postgres create job --from=cronjob/pg-dump dump-test`.

</details>

### 🐘 Postgres app passwords

<details>
<summary><code>apps/prod/postgres/postgres-app-passwords.sops.yaml</code></summary>

| | |
|---|---|
| Secret | `postgres-app-passwords` in `postgres`. One key per app: the key is the role and database name, the value its password |
| Used by | the `app-databases` Job, which creates each role and database and sets the password. Each app gets a copy of its own password in its namespace (Authentik: M5 PR 5) |
| Source | generated: `openssl rand` |
| Keys | `authentik` |
| Created | 27 Oct 2026 ([#36](https://github.com/GreenMachine582/homelab-cluster/pull/36)) |

```bash
scripts/sops-secret.sh apps/prod/postgres/postgres-app-passwords.sops.yaml postgres-app-passwords postgres \
  authentik=gen        # one KEY=gen per app. Re-running regenerates them all, so add an app with sops "$f"
```

To read one back, for example to make the app's own copy (needs the private key):

```bash
sops -d --extract '["data"]["authentik"]' "$f" | base64 -d
```

➕ **Add an app, or 🔄 rotate one:** run `sops "$f"` and add or change the key under `stringData:` (sops re-encrypts it
on save), or recreate the file with every key. Then bump `homelab/run` in `apps/base/postgres/app-databases-job.yaml`
so the Job runs again and sets the password. Update the app's own copy in the same PR.

</details>

### 🔑 Authentik secrets

<details>
<summary><code>apps/prod/authentik/authentik-secrets.sops.yaml</code></summary>

| | |
|---|---|
| Secret | `authentik-secrets` in `authentik`, mounted as env by the chart (`authentik.existingSecret`) |
| `AUTHENTIK_SECRET_KEY` | generated. Signs cookies and makes user IDs. **Never change it after the first start:** every session and some stored data break |
| `AUTHENTIK_POSTGRESQL__PASSWORD` | copied from `postgres-app-passwords` › `authentik`. The two must match |
| `AUTHENTIK_BOOTSTRAP_PASSWORD` | typed in, kept in your password manager. `akadmin`'s password, applied **only on the first start** of an empty database |
| `AUTHENTIK_BOOTSTRAP_EMAIL` | typed in: `akadmin`'s email. It's in the secret so it stays out of this public repo |
| Created | 27 Oct 2026 (M5 PR 5) |

```bash
scripts/sops-secret.sh apps/prod/authentik/authentik-secrets.sops.yaml authentik-secrets authentik \
  AUTHENTIK_SECRET_KEY=gen:60 \
  AUTHENTIK_POSTGRESQL__PASSWORD=sops:apps/prod/postgres/postgres-app-passwords.sops.yaml:authentik \
  AUTHENTIK_BOOTSTRAP_PASSWORD=ask \
  AUTHENTIK_BOOTSTRAP_EMAIL=ask
```

🩹 **Recreating it after a loss:** the secret key must be the one already in use, so don't regenerate it. Decrypt it
from git history if needed, or pass it with `AUTHENTIK_SECRET_KEY=ask`. Only an empty database can take a new key.

🔄 **Rotate:**
- **Database password:** change `authentik` in `postgres-app-passwords` (`sops "$f"`) and bump `homelab/run` in
  `app-databases-job.yaml`, then recreate this file with the same command. Keep the secret key: pass it as `ask` with
  the current value. Merge both in one PR, then restart Authentik:
  `kubectl -n authentik rollout restart deploy`.
- **akadmin password:** change it in the Authentik UI. The bootstrap value isn't read again.
- **Secret key:** don't.

</details>

### 📈 Authentik Grafana OIDC client

<details>
<summary><code>apps/prod/authentik/authentik-grafana-oidc.sops.yaml</code></summary>

| | |
|---|---|
| Secret | `authentik-grafana-oidc` in `authentik`, key `AUTHENTIK_GRAFANA_CLIENT_SECRET`, as env on the server and worker (`global.envFrom`) |
| Used by | `apps/base/authentik/blueprints/grafana.yaml` (`client_secret: !Env …`). Grafana's own secret (M5 PR 6) holds a copy, and the two must match |
| Source | generated |
| Created | 27 Oct 2026 (Authentik blueprints PR) |

```bash
scripts/sops-secret.sh apps/prod/authentik/authentik-grafana-oidc.sops.yaml authentik-grafana-oidc authentik \
  AUTHENTIK_GRAFANA_CLIENT_SECRET=gen:64
```

Grafana's copy, in PR 6, uses the source `sops:apps/prod/authentik/authentik-grafana-oidc.sops.yaml:AUTHENTIK_GRAFANA_CLIENT_SECRET`.

🔄 **Rotate:** recreate this file and Grafana's copy in one PR. A changed Secret doesn't restart pods, so after the
merge run `kubectl -n authentik rollout restart deploy`. The worker re-applies the blueprints at start, with the new
value.

</details>
