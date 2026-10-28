# 🔑 Authentik

Authentik (`https://auth.home.green-tech-hub.com`) is the cluster's single sign-on. Its config is code:
**blueprints** in `apps/base/authentik/blueprints/`. Users and their group memberships are the exception and stay
in the UI, because the repo is public.

**Quick links:** [📦 Blueprints](#-blueprints) · [🔄 How changes apply](#-how-changes-apply) ·
[🚪 Access](#-access) · [🔗 Social login](#-social-login) · [➕ Adding an application](#-adding-an-application) · [🩺 Troubleshooting](#-troubleshooting)

---

## 📦 Blueprints

There's one file per concern. Each starts with a `metaapplyblueprint` for any default it changes, so the order they
apply in doesn't matter.

| File | Sets |
|---|---|
| `mfa.yaml` | Default login flow: users without an MFA device must enroll one (TOTP or WebAuthn) |
| `brand.yaml` | The branding, from the variables in its `context:` ([Changing the brand](#-changing-the-brand)): the default brand's title, logo and favicon, and the login page's title. Also the embedded outpost's `authentik_host` = `https://auth.home…` |
| `admins.yaml` | Group `homelab-admins`: Authentik superusers, with access to every application |
| `grafana.yaml` | OAuth2 provider + application `grafana` (client secret from `authentik-grafana-oidc`), group `grafana-users`, and its access bindings |
| `sources.yaml` | GitHub, Google and Discord login sources (link-only, credentials from `authentik-social-sources`), the `homelab-source-authentication` flow (MFA, then login), and the buttons on the login page |

- **Change them in git, not the UI.** UI edits to objects a blueprint defines are reverted on the next apply.
- **Syntax:** the [blueprint docs](https://docs.goauthentik.io/customize/blueprints/).
  - `!Find` looks up an existing object.
  - `!KeyOf` refers to an entry's `id` in the same file.
  - `!Env` reads the worker's environment, which is how secrets reach a blueprint.
  - `!Context` reads a variable from the file's `context:` block, and `!Format` builds a string from values
    (`%s` placeholders).

### 🎨 Changing the brand

Edit the `context:` block at the top of `brand.yaml`, and nothing else:

| Variable | Used for |
|---|---|
| `brand_name` | The brand title (browser tab) and the login page's "Welcome to …!" |
| `ui_commit` | The `greentechhub-ui` commit the images come from. Bump it to pick up a new logo |
| `logo_path`, `favicon_path` | The image paths inside that repo |

The variables live in the blueprint file, not in the worker's environment, on purpose: Authentik re-applies a
blueprint only when its file changes, so an environment value wouldn't take effect. After the merge the worker
restarts and applies it. Check the login page in both light and dark mode.

## 🔄 How changes apply

No Ansible play or manual step is needed. The path is git → Flux → ConfigMap → worker:
1. kustomize builds two ConfigMaps from the same files (`apps/base/authentik/kustomization.yaml`):
   - `authentik-blueprints`, which the chart mounts on the worker at `/blueprints/mounted/cm-authentik-blueprints/`.
   - `authentik-blueprints-hash`, which isn't mounted and exists only for its content-hashed name.
2. `kustomizeconfig.yaml` writes that hashed name into the worker's pod annotation `homelab-blueprints`. Any
   blueprint edit changes it, so Helm rolls the worker.
3. At start, the worker's discovery task registers every file and applies those whose content changed. Discovery also
   runs every hour, as a backstop.

> [!NOTE]
> `authentik-blueprints` keeps a fixed name on purpose. Authentik records each blueprint by its file path and
> its `metadata.name`, and the name must be unique. A hashed mount path would look like a new file with a name
> that's already taken, and discovery would fail.

**Check they applied:** go to Admin interface → Customization → Blueprints. Each `homelab - …` entry should show
**successful**, with a recent *last applied*.

## 🚪 Access

An application with **no** policy bindings is open to every Authentik user. So every application here gets
bindings:

| Group | Who | Bound to |
|---|---|---|
| `homelab-admins` | You, and anyone who administers the homelab. Authentik superusers | Every application, order 0 |
| `<slug>-users` (e.g. `grafana-users`) | Anyone who may use that one application | That application, order 10 |

- The policy engine mode is `any`, so being in either group is enough. Everyone else gets *access denied* from
  Authentik before the app sees them.
- **Membership is managed in the UI:** Admin interface → Directory → Groups → the group → Users → Add existing user.
  Blueprints never set `users`, so they leave memberships alone.
- **Roles inside an app**, such as Grafana Viewer, Editor or Admin, come from the `groups` claim in the ID token
  (the `profile` scope). The app maps them in its own config. For example, Grafana's `role_attribute_path` (M5 PR 6)
  maps `homelab-admins` to Admin and everyone else to Viewer.

## 🔗 Social login

The login page has GitHub, Google and Discord buttons (`sources.yaml`). They're **link-only**:
- No source has an enrollment flow, and users match by the provider's account ID, never by email. A social account
  that isn't linked to an Authentik user is refused, and no user is created.
- A social login still asks for the user's Authentik MFA device. Its flow, `homelab-source-authentication`, runs the
  default MFA stage before logging in.
- `akadmin` keeps password + MFA as the break-glass login. Don't link it.

**Linking an account:** sign in with your password, open your user settings (the gear icon) → Connected services,
and connect each provider. From then on that button signs you in.

**Unlinking:** the same page, or Admin interface → Directory → Users → the user → Connected services.

<details>
<summary>🛠️ <b>Creating the provider apps</b></summary>

Every provider gets the callback `https://auth.home.green-tech-hub.com/source/oauth/callback/<slug>/`, where the slug is
`github`, `google` or `discord`. The browser carries the redirect, so `auth.home` doesn't need to be public.

| Provider | Where | Notes |
|---|---|---|
| GitHub | Settings → Developer settings → OAuth Apps → New OAuth app | Homepage `https://auth.home.green-tech-hub.com`; generate a client secret |
| Google | Cloud Console → a new project → Google Auth Platform | Audience *External*, then **publish** the app (Testing limits it to listed test users); data access scopes `openid`, `email`, `profile`; Clients → *Web application* with the callback as an authorized redirect URI |
| Discord | Developer Portal → New Application → OAuth2 | Add the callback under Redirects; copy the client ID and reset the secret |

Put the IDs and secrets in `authentik-social-sources` ([SECRETS.md](SECRETS.md#-authentik-social-login-sources)).

</details>

## ➕ Adding an application

1. **Blueprint:** copy the template below to `apps/base/authentik/blueprints/<slug>.yaml` and replace `<slug>`,
   `<Name>` and `<host>`. Check the redirect path in the app's OIDC docs (Grafana's is `/login/generic_oauth`).
2. **Register it:** add the file to **both** `files` lists in `apps/base/authentik/kustomization.yaml`; they share a
   YAML anchor, so in practice it's one list.
3. **Client secret:** create it in WSL from the OneDrive clone, on your branch:
   ```bash
   scripts/sops-secret.sh apps/prod/authentik/authentik-<slug>-oidc.sops.yaml authentik-<slug>-oidc authentik \
     AUTHENTIK_<SLUG>_CLIENT_SECRET=gen:64
   ```
   Then:
   - List it in `apps/prod/authentik/kustomization.yaml`.
   - Add a `secretRef` for it to the HelmRelease's `global.envFrom`.
   - Add an entry to [SECRETS.md](SECRETS.md).
   - The app gets its own copy: in its namespace, create it with `KEY=sops:apps/prod/authentik/authentik-<slug>-oidc.sops.yaml:AUTHENTIK_<SLUG>_CLIENT_SECRET`.
4. **The app's side:**
   - issuer `https://auth.home.green-tech-hub.com/application/o/<slug>/`
   - client ID `<slug>`
   - the secret from step 3
   - scopes `openid email profile`
5. **After merge:**
   - The blueprint shows successful.
   - Add people to `<slug>-users` in the UI.
   - Check that a user outside both groups is denied.

For an app with no OIDC support, the route is a proxy provider with forward-auth through the embedded outpost. That's
not used yet; it will have its own template when the first one lands.

<details>
<summary>📄 <b>Template: <code>blueprints/&lt;slug&gt;.yaml</code></b></summary>

```yaml
# yaml-language-server: $schema=https://goauthentik.io/blueprints/schema.json
# <Name>'s OIDC client, and who may use it (docs/AUTHENTIK.md).
version: 1
metadata:
  name: homelab - <Name>
entries:
  - model: authentik_blueprints.metaapplyblueprint
    attrs:
      identifiers:
        name: Default - Provider authorization flow (implicit consent)
      required: false
  - model: authentik_blueprints.metaapplyblueprint
    attrs:
      identifiers:
        name: Default - Provider invalidation flow
      required: false

  - model: authentik_providers_oauth2.oauth2provider
    id: provider
    identifiers:
      name: <slug>
    attrs:
      authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
      invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
      client_type: confidential
      client_id: <slug>
      client_secret: !Env AUTHENTIK_<SLUG>_CLIENT_SECRET
      redirect_uris:
        - matching_mode: strict
          url: https://<host>.home.green-tech-hub.com/<redirect path>
      signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
      property_mappings:
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]

  - model: authentik_core.application
    id: app
    identifiers:
      slug: <slug>
    attrs:
      name: <Name>
      provider: !KeyOf provider
      meta_launch_url: https://<host>.home.green-tech-hub.com

  # Listed by name only, so this file works whichever blueprint applies first.
  - model: authentik_core.group
    id: admins
    identifiers:
      name: homelab-admins
  - model: authentik_core.group
    id: users
    identifiers:
      name: <slug>-users
  - model: authentik_policies.policybinding
    identifiers:
      target: !KeyOf app
      group: !KeyOf admins
    attrs:
      order: 0
  - model: authentik_policies.policybinding
    identifiers:
      target: !KeyOf app
      group: !KeyOf users
    attrs:
      order: 10
```

</details>

## 🩺 Troubleshooting

<details>
<summary>🧩 <b>A blueprint isn't listed, or doesn't apply</b></summary>

1. Check that the worker has the file:
   `kubectl -n authentik exec deploy/authentik-worker -- ls /blueprints/mounted/cm-authentik-blueprints`
2. Validate it without applying (run it on one line):
   `kubectl -n authentik exec deploy/authentik-worker -- ak apply_blueprint --dry-run mounted/cm-authentik-blueprints/<file>.yaml`
   If it's invalid, it prints `Blueprint invalid` and the reasons.
3. Apply it by hand with the same command without `--dry-run`. This applies the file but doesn't register it in the
   Blueprints list; only discovery does that.
4. Re-run discovery by restarting the worker: `kubectl -n authentik rollout restart deploy/authentik-worker`. Then
   check the log:
   `kubectl -n authentik logs deploy/authentik-worker | grep -E 'blueprints_discovery|apply_blueprint|"level": "error"'`.
   Look for *Task started* and *Task finished*, not just *Task enqueued*.

On 27 Oct 2026, the first start after the blueprints landed queued discovery but never ran it. The blueprints were
then applied by hand with step 3.

</details>

<details>
<summary>🔒 <b>Locked out by MFA</b></summary>

`akadmin` is the break-glass account; keep its password and MFA device somewhere separate from your own. If both are
gone, open a shell on the worker and make a one-time recovery link for a user:
`kubectl -n authentik exec -it deploy/authentik-worker -- ak create_recovery_key 10 akadmin`.
The link is valid for 10 minutes. Open it on `https://auth.home.green-tech-hub.com`.

</details>
