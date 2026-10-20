# Contributing

How changes reach the cluster. Merging to `main` **is** the deploy: Flux applies `main` within a minute or two.
The same commit rules apply in [HomeLab](https://github.com/GreenMachine582/HomeLab/blob/main/CONTRIBUTING.md).

## Flow

```
branch ──► commits (signed) ──► PR to main ──► checks pass ──► merge ──► Flux reconciles ──► verify
```

- `main` is protected. Changes go through a PR. Direct pushes, force-pushes and branch deletion are blocked,
  with no bypass.
- Every commit on `main` must be signed.
- Nothing is changed with `kubectl apply`/`edit` by hand. Flux puts back anything that drifts from git.
- One change per PR, small enough to roll back by reverting it.

**Branch names:** `<area>/<short-description>`, for example `m3/cilium-adoption`, `m4/lb-ipam`,
`docs/status-contributing`.

**Commit and push from Windows.** Windows git signs commits with an SSH key. WSL has no signing key, so its
commits are rejected on `main`. `git log --show-signature` reports "No signature" because no allowed-signers file is
set. Check a commit with `git cat-file -p <sha> | grep "BEGIN SSH SIGNATURE"` instead.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org):

```
type(scope): subject

Why the change was needed, and what it will do to the cluster when Flux applies it.

Co-Authored-By: …            (optional trailers)
```

- **type**: one of
  | type       | for                                                         |
  |------------|-------------------------------------------------------------|
  | `feat`     | something new in the cluster: a service, controller, policy  |
  | `fix`      | something that was broken                                   |
  | `docs`     | documentation only                                          |
  | `chore`    | housekeeping that changes nothing running (comments, layout) |
  | `refactor` | restructuring with the same result in the cluster           |
  | `test`     | smoke tests and other temporary checks                      |
  | `ci`       | GitHub Actions workflows                                    |
  | `build`    | chart and image versions, Flux's own manifests              |
  | `perf`     | resource requests and limits, tuning                        |
  | `revert`   | undoing an earlier commit                                   |
- **scope** (optional): lowercase. Use the component or milestone: `cilium`, `flux`, `smoke`, `m3`, `m4`.
- **subject**: imperative or descriptive, no trailing period. The whole first line is at most 100 characters.
- **`!`** after the type or scope marks a breaking change, for example one that recreates a workload or needs a
  manual step: `feat(cilium)!: switch to native routing`.

Examples:

```
test(m3): smoke app to prove Flux apply + SOPS decryption
build(cilium): 1.20.1 -> 1.20.3
docs: rpi-01 and rpi-02 joined; Envoy only on laptop-01 and rpi-03
```

**The PR title follows the same format.** GitHub uses it for squash merges.

### The check

`.github/workflows/commit-style.yml` runs on every PR to `main`. Its `commit-style` job checks the PR title and each
non-merge commit in the PR, and is a required status check. GitHub's own `Merge pull request …` commits and
`git revert`'s `Revert "…"` are exempt. Commits from before the check aren't re-checked.

To fix a failing commit: `git commit --amend` (last commit) or `git rebase -i main`, then
`git push --force-with-lease` to the PR branch. Never to `main`.

## Before opening a PR

- Render what you changed: `kubectl kustomize apps/prod/<service>` or `kubectl kustomize infrastructure/controllers`.
- Secrets only in `*.sops.yaml`, encrypted (`sops --encrypt --in-place`) before the first commit. `.sops.yaml`
  encrypts `data` and `stringData` only. Never commit a plaintext Secret, not even on a branch: the repo is public.
- Helm charts and images are pinned to exact versions.
- Workloads are multi-arch and set resource requests and limits. Anything needing L7/FQDN/TLS policy or the Gateway
  selects `homelab/l7-proxy: supported`.
- For a Helm release Flux adopts or changes, put the values diff against the deployed release in the PR. HomeLab's
  `cluster_status.yml` prints the deployed Cilium values.
- In the PR body, say what Flux will do on merge (create, upgrade, restart, prune) and how to check it.

## After merging

```bash
flux reconcile kustomization flux-system --with-source   # don't wait for the poll
flux get kustomizations                                   # all Ready at the merge commit
flux get helmreleases -A
```

Then the checks from the PR body. If something breaks, revert the PR with a new PR. Use `flux suspend` only to stop
a release from being retried while the revert is on its way.
