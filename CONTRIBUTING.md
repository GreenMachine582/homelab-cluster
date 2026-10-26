# 🤝 Contributing

How changes reach the cluster. Merging to `main` **is** the deploy: Flux applies `main` within a minute or two.
The same commit rules apply in [HomeLab](https://github.com/GreenMachine582/HomeLab/blob/main/CONTRIBUTING.md).

**Quick links:** [🔀 Flow](#-flow) · [✍️ Commit messages](#️-commit-messages) ·
[✅ Before opening a PR](#-before-opening-a-pr) · [🚀 After merging](#-after-merging) ·
[🧩 Adding a service](docs/ADDING_A_SERVICE.md) · [🔐 Secrets](docs/SECRETS.md)

---

## 🔀 Flow

```
branch ──► commits (signed) ──► PR to main ──► checks pass ──► merge ──► Flux reconciles ──► Discord ──► verify
```

- 🔒 `main` is protected. Changes go through a PR. Direct pushes, force-pushes and branch deletion are blocked,
  with no bypass.
- ✍️ Every commit on `main` must be signed.
- 🚫 Nothing is changed with `kubectl apply`/`edit` by hand. Flux puts back anything that drifts from git.
- 🎯 One change per PR, small enough to roll back by reverting it.
- ➕ Update an open PR by adding commits, or by merging `main` into the branch. Never rebase and force-push.

**Branch names:** `<area>/<short-description>`, for example `m4/lb-ipam`, `fix/cloudflared-http2`,
`docs/adding-a-service`.

> [!IMPORTANT]
> **Commit and push from Windows.** Windows git signs commits with an SSH key. WSL has no signing key, so its
> commits are rejected on `main`. `git log --show-signature` reports "No signature" because no allowed-signers file
> is set. Check a commit with `git cat-file -p <sha> | grep "BEGIN SSH SIGNATURE"` instead.

---

## ✍️ Commit messages

[Conventional Commits](https://www.conventionalcommits.org):

```
type(scope): subject

Why the change was needed, and what it will do to the cluster when Flux applies it.

Co-Authored-By: …            (optional trailers)
```

- **scope** (optional): lowercase, naming the component or milestone: `cilium`, `flux`, `cloudflared`, `m4`.
- **subject**: imperative or descriptive, no trailing period. The whole first line is at most **100 characters**.
- **`!`** after the type or scope marks a breaking change, for example one that recreates a workload or needs a
  manual step: `feat(cilium)!: switch to native routing`.
- **The PR title follows the same format.** GitHub uses it for squash merges.

<details>
<summary><b>Types</b></summary>

| type       | for                                                          |
|------------|--------------------------------------------------------------|
| `feat`     | something new in the cluster: a service, controller, policy  |
| `fix`      | something that was broken                                    |
| `docs`     | documentation only                                           |
| `chore`    | housekeeping that changes nothing running (comments, layout) |
| `refactor` | restructuring with the same result in the cluster            |
| `test`     | smoke tests and other temporary checks                       |
| `ci`       | GitHub Actions workflows                                     |
| `build`    | chart and image versions, Flux's own manifests               |
| `perf`     | resource requests and limits, tuning                         |
| `revert`   | undoing an earlier commit                                    |

</details>

<details>
<summary><b>Examples</b></summary>

```
feat(gateway): shared Gateway with wildcard cert and HTTPS redirect (M4)
fix(cloudflared): HTTP/2 transport, liveness on /healthcheck, one replica
build(cilium): 1.20.1 -> 1.20.3
docs: runbook for adding a service behind the Gateway (M4)
```

</details>

<details>
<summary><b>The <code>commit-style</code> check</b></summary>

`.github/workflows/commit-style.yml` runs on every PR to `main`. Its `commit-style` job checks the PR title and each
non-merge commit in the PR, and is a required status check. GitHub's own `Merge pull request …` commits and
`git revert`'s `Revert "…"` are exempt. Commits from before the check aren't re-checked.

To fix a bad message, do it **before pushing**: `git commit --amend` for the last commit. Once a commit is pushed,
don't rewrite it. Instead, cherry-pick the changes onto a new branch with fixed messages, open a new PR, and close
the old one.

</details>

---

## ✅ Before opening a PR

- [ ] 🧪 Render what you changed: `kubectl kustomize apps/prod`, `kubectl kustomize infrastructure/configs` or
  `kubectl kustomize infrastructure/controllers`.
- [ ] 🔐 Secrets only in `*.sops.yaml`, encrypted through a pipe as in [docs/SECRETS.md](docs/SECRETS.md) before
  the first commit. `.sops.yaml` encrypts `data` and `stringData` only. **Never commit a plaintext Secret, not even
  on a branch: the repo is public.**
- [ ] 📒 A PR that adds or changes a `*.sops.yaml` adds or updates its entry in [docs/SECRETS.md](docs/SECRETS.md):
  what it holds, where the value comes from, and the commands to recreate it.
- [ ] ☁️ Anything set up by hand (Cloudflare dashboard, DNS, tunnel) is recorded in the
  [Cloudflare setup](docs/M4_PLATFORM.md#cloudflare-setup-manual) table.
- [ ] 📌 Helm charts and images are pinned to exact versions. Renovate (`.github/renovate.json5`) opens the bumps
  and automerges minor and patch ones. To hold a version, add a disabled `packageRules` entry that says why.
- [ ] 🧩 New services follow [docs/ADDING_A_SERVICE.md](docs/ADDING_A_SERVICE.md) (layout, Gateway route, tunnel).
- [ ] 🏗️ Workloads are multi-arch and set resource requests and limits. Anything needing L7/FQDN/TLS policy or the
  Gateway selects `homelab/l7-proxy: supported`.
- [ ] 📊 For a Helm release Flux adopts or changes, the PR has the values diff against the deployed release.
  HomeLab's `cluster_status.yml` prints the deployed Cilium values.
- [ ] 📝 The PR body says what Flux will do on merge (create, upgrade, restart, prune) and how to check it.

---

## 🚀 After merging

💬 Discord's `#homelab-deploys` shows when Flux pulls the merge commit, then what each Kustomization and
HelmRelease applies, or why it failed.

<details>
<summary><b>Check by hand, or skip the poll interval</b></summary>

```bash
flux reconcile kustomization flux-system --with-source   # don't wait for the poll
flux get kustomizations                                   # all Ready at the merge commit
flux get helmreleases -A
```

</details>

Then run the checks from the PR body.

> [!WARNING]
> If something breaks, revert the PR with a new PR. Use `flux suspend` only to stop a release from being retried
> while the revert is on its way.
