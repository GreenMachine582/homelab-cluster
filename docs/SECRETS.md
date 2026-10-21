# Secrets

Every SOPS-encrypted file in this repo, what it holds, where the value comes from, and how to recreate it. A PR
that adds or changes a `*.sops.yaml` updates this file in the same PR.

## How encryption works here

- `.sops.yaml` holds the age **public** key and encrypts only `data` / `stringData`. Encrypting needs only that,
  so anyone with the repo can (re)create a secret.
- Decrypting or editing needs the age **private** key at `~/.config/sops/age/keys.txt` in WSL (HomeLab
  `sops_age_key_file`). Flux has its own copy as the `sops-age` secret in `flux-system` (HomeLab
  `playbooks/flux_bootstrap.yml`).
- If the private key is lost, nothing here can be decrypted. Re-issue every value below, generate a new age key,
  put its public key in `.sops.yaml` (and HomeLab `sops_age_recipient`), re-run `flux_bootstrap.yml`, and
  recreate each file.

## Recreating a secret

Run in WSL, from the root of the **Windows (OneDrive) clone**, on a branch made there. Commits are signed from
Windows, and WSL can't sign:

```bash
cd /mnt/c/Users/Chad/OneDrive/Desktop/Python-Projects/HomeLab/homelab-cluster
```

The value is read at a hidden prompt and only goes through a pipe, so it never lands on disk or in shell history:

```bash
read -rs VALUE; echo        # paste the value, press Enter (nothing is shown)
echo ${#VALUE}              # length only; 0 means nothing was stored, run read again
```

Then build the Secret and encrypt it straight into place (`f`, the name, namespace and key come from the entry
below):

```bash
kubectl create secret generic <name> -n <namespace> \
  --from-literal=<key>="$VALUE" --dry-run=client -o yaml \
| sops --encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"
unset VALUE
grep -c 'ENC\[' "$f"        # 2 or more: the value plus the sops MAC
```

To change a single value later instead: `sops "$f"` opens it decrypted in your editor and re-encrypts on save
(needs the private key).

Check the result has no plaintext before committing: every value under `data:` must be `ENC[...]`.

## Secret inventory

### `infrastructure/configs/cert-manager/cloudflare-api-token.sops.yaml`

| | |
|---|---|
| Secret | `cloudflare-api-token` in `cert-manager`, key `api-token` |
| Used by | ClusterIssuers `letsencrypt-staging` and `letsencrypt` (DNS-01) |
| Source | Cloudflare dashboard → My Profile → API Tokens → Create Token → Custom token |
| Scope | Permissions: Zone · DNS · Edit, and Zone · Zone · Read. Zone resources: Include · Specific zone · `green-tech-hub.com`. No client IP filter, no expiry |
| Created | 21 Oct 2026 ([#14](https://github.com/GreenMachine582/homelab-cluster/pull/14)) |

Check the token before encrypting it (after the `read`):

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

**Rotate:** create a new token, recreate the file as above, PR and merge, wait for
`kubectl get clusterissuers` to show both Ready, then delete the old token in Cloudflare.

### `infrastructure/configs/cloudflared/tunnel-credentials.sops.yaml`

| | |
|---|---|
| Secret | `cloudflared-tunnel-credentials` in `cloudflared`, key `credentials.json` |
| Used by | the cloudflared Deployment (the `homelab` tunnel) |
| Source | `cloudflared tunnel create homelab` writes `~/.cloudflared/<TUNNEL_ID>.json` in WSL |
| Needs | the cloudflared CLI (HomeLab `controller.yml -K --tags cloudflared`) and `~/.cloudflared/cert.pem` from `cloudflared tunnel login` |
| Created | 21 Oct 2026 |

A file this time, so use `--from-file` instead of `read` + `--from-literal`:

```bash
cd /mnt/c/Users/Chad/OneDrive/Desktop/Python-Projects/HomeLab/homelab-cluster
f=infrastructure/configs/cloudflared/tunnel-credentials.sops.yaml
kubectl create secret generic cloudflared-tunnel-credentials -n cloudflared \
  --from-file=credentials.json="$HOME/.cloudflared/<TUNNEL_ID>.json" --dry-run=client -o yaml \
| sops --encrypt --filename-override "$f" --input-type yaml --output-type yaml /dev/stdin > "$f"
grep -c 'ENC\[' "$f"
```

**Lost the JSON?** Regenerate it from the tunnel (needs `cert.pem`), then encrypt as above:

```bash
cloudflared tunnel token --cred-file "$HOME/.cloudflared/<TUNNEL_ID>.json" homelab
```

**Rotate** (new tunnel secret): `cloudflared tunnel delete homelab` breaks public access until the new one is up, so
create `homelab2`, route its hostnames (`cloudflared tunnel route dns --overwrite-dns homelab2 <host>`), update
`tunnel:` in `configmap.yaml` and this secret in one PR, then delete the old tunnel.

`~/.cloudflared/cert.pem` is account-level: it can create and delete tunnels and DNS records in the zone. It isn't
in git. Keep it at mode 600 in WSL, or delete it and run `cloudflared tunnel login` again when needed.

### `infrastructure/configs/flux-notifications/discord-webhook.sops.yaml`

| | |
|---|---|
| Secret | `discord-webhook` in `flux-system`, key `address` |
| Used by | Flux Provider `discord`, Alert `homelab-deploys` (deploy notifications) |
| Source | Discord: the `#homelab-deploys` channel → Edit Channel → Integrations → Webhooks → New Webhook → Copy Webhook URL |
| Created | 21 Oct 2026 |

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

**Rotate:** delete the webhook in Discord (that revokes it at once), make a new one, recreate the file as above.
