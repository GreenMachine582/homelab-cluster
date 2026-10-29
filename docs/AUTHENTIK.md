# 🔑 Authentik

Authentik (`https://auth.home.green-tech-hub.com`) is the cluster's single sign-on. Its config is code:
**blueprints** in `apps/base/authentik/blueprints/`. Users and their group memberships are the exception and stay
in the UI, because the repo is public.

**Quick links:** [📦 Blueprints](#-blueprints) · [🔄 How changes apply](#-how-changes-apply) ·
[🚪 Access](#-access) · [🔗 Social login](#-social-login) · [➕ Adding an application](#-adding-an-application) · [🚨 Alerts](#-alerts) ·
[🌍 Public access](#-public-access) · [📣 Advisories](#-security-advisories) ·
[🩺 Troubleshooting](#-troubleshooting)

---

## 📦 Blueprints

There's one file per concern. Each starts with a `metaapplyblueprint` for any default it changes, so the order they
apply in doesn't matter.

> [!IMPORTANT]
> A `metaapplyblueprint` **re-applies the whole default blueprint** every time, and resets whatever that default
> sets. *Default - Authentication flow* sets the login title to "Welcome to authentik!". So only `brand.yaml`
> meta-applies it, then sets the title. Any other file that needs the default login flow meta-applies
> `homelab - Brand and outpost host` instead (as `mfa.yaml` and `sources.yaml` do).

| File | Sets |
|---|---|
| `mfa.yaml` | Default login flow: users without an MFA device must enroll one (TOTP or WebAuthn) |
| `brand.yaml` | The branding, from the variables in its `context:` ([Changing the brand](#-changing-the-brand)): the default brand's title, logo and favicon, and the login page's title. Also the embedded outpost's `authentik_host` = `https://auth.green-tech-hub.com` (the public name, [Public access](#-public-access)) |
| `admins.yaml` | Group `homelab-admins`: Authentik superusers, with access to every application |
| `grafana.yaml` | OAuth2 provider + application `grafana` (client secret from `authentik-grafana-oidc`), group `grafana-users`, and its access bindings |
| `hardening.yaml` | No username enumeration (`pretend_user_exists`), no "remember me", 12-hour sessions, the `homelab-reputation` block on the login flow, and security events to Discord ([Alerts](#-alerts)) |
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

If the login page says "Welcome to authentik!" again, something re-applied the default login flow after
`brand.yaml`, for example an Authentik upgrade that changed that default. Re-apply the brand: Admin →
Customization → Blueprints → `homelab - Brand and outpost host` → Apply.

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
  (the `profile` scope). The app maps them in its own config. For example, Grafana's `role_attribute_path`
  (`apps/base/monitoring/helmrelease.yaml`) maps `homelab-admins` to Admin and everyone else to Viewer.

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

Every provider gets the callback `https://auth.green-tech-hub.com/source/oauth/callback/<slug>/` (public, since M5.5
PR 4b), where the slug is `github`, `google` or `discord`. Google and Discord also keep the `auth.home` callback, so the
buttons work on both names. A GitHub OAuth app has only one callback host, so GitHub login works on the public name
only.

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
   - **Skip the app's own login page** where it can (Grafana: `auto_login: true`), so opening the app goes straight
     to Authentik. Keep a local break-glass login reachable for when Authentik is down (Grafana:
     `/login?disableAutoLogin=true`).
   - **Sign-out** redirects to `https://auth.home.green-tech-hub.com/application/o/<slug>/end-session/` (Grafana:
     `auth.signout_redirect_url`). Without it, auto-login signs the user straight back in.
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
      # Required: without it the provider has no grant types (troubleshooting below).
      grant_types: [authorization_code, refresh_token]
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

## 🚨 Alerts

`hardening.yaml` posts Authentik events to Discord `#homelab-alerts` (the Alertmanager channel), through its Slack-format
endpoint (`<webhook>/slack`, secret [`authentik-alerts-webhook`](SECRETS.md#-authentik-alerts-webhook)):

| Rule | Events | Severity |
|---|---|---|
| `homelab-security-events` | `login_failed`, `suspicious_request` | warning |
| `homelab-error-events` | `configuration_error`, `system_exception`, `policy_exception` | alert |
| `homelab-change-events` | `model_created`, `model_updated`, `model_deleted`: changes made in the UI or API. Blueprint applies record none | notice |

**Brute force:** each failed login lowers the IP's and the username's reputation. At `-5` the login flow stops applying
to them ("Flow does not apply to current user"), before any password is checked. Scores recover over time. To let
someone back in sooner: Admin → Customization → Reputation scores → delete theirs.

**Test it** (LAN): sign in at `auth.home` with a wrong password 6 times. Each try posts a `login_failed`, and the next
try is refused. Then delete the score. A rename in the UI (for example a group's attribute) posts a change event.

## 🌍 Public access

`https://auth.green-tech-hub.com` (M5.5 PR 4b) serves only what a user needs: signing in, social login, and their own
settings (`apps/base/authentik/httproute-public.yaml`). The admin interface stays on `auth.home`, LAN only.

| Public | Not public |
|---|---|
| `/` (redirects to the login flow), `/if/flow/`, `/if/user/`, `/flows/`, `/static/`, `/media/`, `/application/` (OIDC), `/source/` (social login callbacks), `/outpost.goauthentik.io/` (proxy providers), `/api/v3/`, `/ws/` | `/if/admin/` and every other path: the Gateway answers 404, and Cloudflare blocks `/if/admin*` before it gets there |

- `/api/v3/` is open because the flow executor and the user interface call it. It checks the session's permissions,
  so a non-admin can't use the admin endpoints. Admins sign in to the admin UI on `auth.home` only.
- Cloudflare rate-limits `/api/v3/flows/executor/`, and the reputation policy ([Alerts](#-alerts)) blocks repeated
  failed logins ([CLOUDFLARE.md › Rules](CLOUDFLARE.md#-rules)).
- Grafana's OIDC stays on `auth.home`.
- **A user page breaks on the public name:** open the browser's dev tools → Network, find the 404 on a path outside
  the list, and add that prefix to the route in a PR.

## 📣 Security advisories

Once `auth.green-tech-hub.com` is public (M5.5 PR 4), Authentik's login is on the internet, so its CVE fixes can't
wait.

- **Watch:** on GitHub, [`goauthentik/authentik`](https://github.com/goauthentik/authentik) → Watch → Custom →
  **Security alerts**. Advisories also appear on the release notes.
- **Patch within days:** Renovate opens the chart bump once a release is 3 days old. For a security release,
  don't wait: approve or merge it the same day, or bump `version` in `apps/base/authentik/helmrelease.yaml` by
  hand. Read the release notes first; a minor (2026.x) can need a migration.
- **Review, not automerge:** today the chart's patch updates automerge like everything else. M5.5 PR 4 gives
  Authentik (and PR 6 the playground) a Renovate rule with `automerge: false`, so every update to a public app is
  reviewed ([ADDING_A_SERVICE.md › Before going public](ADDING_A_SERVICE.md#-before-going-public)).
- **If a fix isn't out yet:** cut public access with the [kill switch](INCIDENT.md#️-kill-switch). `auth.home` keeps
  working on the LAN.

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
<summary>🚫 <b>An app's login fails with <code>invalid_request</code></b></summary>

The app gets `error=invalid_request`, `error_description=The request is otherwise malformed` back from Authentik.
Grafana shows it as *Login provider denied login request*, and logs the real error:
`kubectl -n monitoring logs deploy/kps-grafana -c grafana | grep 'failed to login'`.

The usual cause is that the OAuth2 provider has no grant types. Since 2026.x, a provider's `grant_types` defaults to
empty, and the authorize endpoint rejects a grant type that isn't listed. Set
`grant_types: [authorization_code, refresh_token]` in its blueprint, as the template does. Check it under Admin →
Applications → Providers → the provider. Found on Grafana, 28 Oct 2026.

</details>

<details>
<summary>🔁 <b>Signing out of an app logs straight back in</b></summary>

The app skips its login page (auto-login) but its sign-out only ends its own session. The Authentik session is still
live, so the next page load goes to Authentik and straight back in. Point the app's sign-out redirect at
`https://auth.home.green-tech-hub.com/application/o/<slug>/end-session/`, as Grafana's `auth.signout_redirect_url`
does in `apps/base/monitoring/helmrelease.yaml`.

</details>

<details>
<summary>🔒 <b>Locked out by MFA</b></summary>

`akadmin` is the break-glass account; keep its password and MFA device somewhere separate from your own. If both are
gone, open a shell on the worker and make a one-time recovery link for a user:
`kubectl -n authentik exec -it deploy/authentik-worker -- ak create_recovery_key 10 akadmin`.
The link is valid for 10 minutes. Open it on `https://auth.home.green-tech-hub.com`.

</details>
