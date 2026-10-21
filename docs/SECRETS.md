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

1. **Where:** in WSL, from the root of the **Windows (OneDrive) clone**, on a branch made there. Commits are signed
   from Windows, and WSL can't sign.
   ```bash
   cd /mnt/c/Users/Chad/OneDrive/Desktop/Python-Projects/HomeLab/homelab-cluster
   ```
2. **Read the value** at a hidden prompt. It only goes through a pipe, so it never lands on disk or in shell history.
   ```bash
   read -rs VALUE; echo        # paste the value, press Enter (nothing is shown)
   echo ${#VALUE}              # length only; 0 means nothing was stored, run read again
   ```
3. **Encrypt it straight into place.** `f`, the name, the namespace and the key come from the entry in the
   inventory below.
   ```bash
   kubectl create secret generic <name> -n <namespace> \
     --from-literal=<key>="$VALUE" --dry-run=client -o yaml \
   | sops --encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"
   unset VALUE
   ```
4. **Check it** before committing. Every value under `data:` must be `ENC[...]`:
   ```bash
   grep -c 'ENC\[' "$f"        # 2 or more: the value plus the sops MAC
   ```

> [!TIP]
> To change one value later, run `sops "$f"`. It opens the file decrypted in your editor and re-encrypts it on save
> (needs the private key). For a file such as a JSON credentials file, use `--from-file=<key>=<path>` instead of
> `read` + `--from-literal`.

---

## 📒 Inventory

| | File | Secret (namespace / key) | Used by |
|---|---|---|---|
| ☁️ | [`cloudflare-api-token.sops.yaml`](#️-cloudflare-api-token) | `cert-manager` / `api-token` | cert-manager DNS-01 |
| 🚇 | [`tunnel-credentials.sops.yaml`](#-cloudflared-tunnel-credentials) | `cloudflared` / `credentials.json` | cloudflared |
| 💬 | [`discord-webhook.sops.yaml`](#-discord-webhook) | `flux-system` / `address` | Flux notifications |

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

After the `read`, check the token before encrypting it:

```bash
curl -s -H "Authorization: Bearer $VALUE" https://api.cloudflare.com/client/v4/user/tokens/verify
# expect "success":true and "status":"active"
```

Then:

```bash
f=infrastructure/configs/cert-manager/cloudflare-api-token.sops.yaml
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=api-token="$VALUE" --dry-run=client -o yaml \
| sops --encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"
unset VALUE
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

It's a file, so this one uses `--from-file`:

```bash
cd /mnt/c/Users/Chad/OneDrive/Desktop/Python-Projects/HomeLab/homelab-cluster
f=infrastructure/configs/cloudflared/tunnel-credentials.sops.yaml
kubectl create secret generic cloudflared-tunnel-credentials -n cloudflared \
  --from-file=credentials.json="$HOME/.cloudflared/<TUNNEL_ID>.json" --dry-run=client -o yaml \
| sops --encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"
grep -c 'ENC\[' "$f"
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
| Used by | Flux Provider `discord`, Alert `homelab-deploys` (deploy notifications) |
| Source | Discord: the `#homelab-deploys` channel → Edit Channel → Integrations → Webhooks → New Webhook → Copy Webhook URL |
| Created | 21 Oct 2026 ([#20](https://github.com/GreenMachine582/homelab-cluster/pull/20)) |

```bash
cd /mnt/c/Users/Chad/OneDrive/Desktop/Python-Projects/HomeLab/homelab-cluster
read -rs VALUE; echo; echo ${#VALUE}      # paste the webhook URL
f=infrastructure/configs/flux-notifications/discord-webhook.sops.yaml
kubectl create secret generic discord-webhook -n flux-system \
  --from-literal=address="$VALUE" --dry-run=client -o yaml \
| sops --encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"
unset VALUE
grep -c 'ENC\[' "$f"
```

🔄 **Rotate:**
1. Delete the webhook in Discord. That revokes it at once.
2. Make a new one.
3. Recreate the file as above.

</details>
