# OpenPhysics `relay`

Orchestration repository for the [OpenPhysics](https://github.com/OpenPhysics) organization. `relay` owns
the **operational** side of the org: the reusable CI/CD workflows member repos call, the cross-repo
automation scripts, the Dependabot templates, and the machine-readable repository catalog.

> Community-health defaults (license, contributing, code of conduct, security policy, issue/PR templates,
> org profile) belong in an `OpenPhysics/.github` repo — GitHub requires those in the special `.github`
> repo so they are inherited org-wide. That repo doesn't exist yet; until it does, member repos keep
> their own `LICENSE` / `CONTRIBUTING.md`.

## Contents

| Path | Purpose |
|---|---|
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | Reusable CI workflow (audit, lint, type-check, test, build) for npm repos |
| [`.github/actions/security-audit/action.yml`](.github/actions/security-audit/action.yml) | Composite action used by `ci.yml`: `npm audit` summary, blocks only on high/critical in direct deps |
| [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) | Reusable GitHub Pages deploy workflow |
| [`.github/workflows/shared-codeql.yml`](.github/workflows/shared-codeql.yml) | Reusable CodeQL analysis ([`doc/codeql.md`](doc/codeql.md)) |
| [`.github/workflows/shared-dependency-review.yml`](.github/workflows/shared-dependency-review.yml) | Reusable dependency review |
| [`.github/workflows/shared-compliance-check.yml`](.github/workflows/shared-compliance-check.yml) | README/CI/Dependabot compliance audit |
| [`.github/workflows/fleet-exec.yml`](.github/workflows/fleet-exec.yml) | Fan a command across many repos and open one PR each (manual dispatch) |
| [`.github/workflows/fleet-health.yml`](.github/workflows/fleet-health.yml) | Weekly lint / type-check / build / test of every active npm repo, reported as a table |
| [`.github/workflows/gitlab-mirror.yml`](.github/workflows/gitlab-mirror.yml) | Daily push of every repo's git history to the GitLab backup group |
| [`.github/workflows/sync-dependabot.yml`](.github/workflows/sync-dependabot.yml) | Validate the Dependabot templates |
| [`.github/workflows/relay-selfcheck.yml`](.github/workflows/relay-selfcheck.yml) | Validate relay's own invariants (catalog schema, Node-version sync, script syntax) |
| [`scripts/`](scripts/) | Repo catalog tools, compliance checks, Dependabot/metadata sync ([`scripts/README.md`](scripts/README.md)) |
| [`config/`](config/) | Canonical Dependabot and GitHub-repo-settings baselines |
| [`structure/repos.json`](structure/repos.json) | Machine-readable catalog of org repositories |
| [`structure/repos.schema.json`](structure/repos.schema.json) | JSON Schema for the catalog |
| [`doc/add-repo.md`](doc/add-repo.md) | Checklist for adding a repo to the catalog |
| [`doc/github-repo-settings.md`](doc/github-repo-settings.md) | GitHub settings/security baseline + apply/check script |
| [`doc/fleet-git.md`](doc/fleet-git.md) | Cheat sheet: everyday git across local checkouts (`pull`/`push`/`status` all) |
| [`doc/fleet-auth.md`](doc/fleet-auth.md) | Setting up the `FLEET_PAT` / GitHub App that lets `fleet-exec` open PRs |
| [`doc/gitlab-mirror.md`](doc/gitlab-mirror.md) | GitLab backup mirror: setup, initial import, periodic sync, restore |
| [`doc/codeql.md`](doc/codeql.md) | CodeQL setup and path-exclusion policy |
| [`doc/biome-bumps.md`](doc/biome-bumps.md) | When bumping `@biomejs/biome`, also sync `biome.json` `$schema` |

## Shared CI

A member repo's `.github/workflows/ci.yml` calls the reusable workflows from this repo:

```yaml
jobs:
  ci:
    uses: OpenPhysics/relay/.github/workflows/ci.yml@main
  dependency-review:
    if: github.event_name == 'pull_request'
    uses: OpenPhysics/relay/.github/workflows/shared-dependency-review.yml@main
  codeql:
    uses: OpenPhysics/relay/.github/workflows/shared-codeql.yml@main
```

Optional compliance checking:

```yaml
  compliance:
    uses: OpenPhysics/relay/.github/workflows/shared-compliance-check.yml@main
    with:
      repo-name: ${{ github.event.repository.name }}
```

`ci.yml` runs the test step automatically when the caller defines a `test` npm script — no per-repo
flag needed. Pass `run-tests: "true"` to force it on (e.g. before a test script exists) or
`run-tests: "false"` to opt out. `ci.yml` is npm-specific; a Python repo (e.g. `pycd48`) runs its
own CI, wiring in `shared-dependency-review.yml` / `shared-codeql.yml` directly if useful.

Pages deploy, for repos that publish to GitHub Pages. Callers use `push` to `main` **and**
`workflow_dispatch`, so a site can be published without waiting for a push:

```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    uses: OpenPhysics/relay/.github/workflows/deploy.yml@main
    permissions:
      contents: read
      pages: write
      id-token: write
```

## Compliance workflow

[`shared-compliance-check.yml`](.github/workflows/shared-compliance-check.yml) runs weekly (Mondays 06:00 UTC)
and on manual dispatch. It reads [`structure/repos.json`](structure/repos.json), clones each catalog repo,
and runs [`scripts/check-repo-compliance.sh`](scripts/check-repo-compliance.sh). Because the fleet spans
multiple languages and repo shapes, this check is deliberately light and mostly **warns** rather than
fails:

- **README & license** — `README.md` present and non-empty (fail); a `LICENSE` file (warn).
- **CI wiring** — `ci.yml` calls this repo's reusable `ci.yml`, `shared-dependency-review.yml`, and
  `shared-codeql.yml` (warn if missing or not yet wired); `.github/dependabot.yml` present for
  npm/Python repos (warn).
- **Node pins** — for npm repos, `engines.node` should track the fleet Node major declared in
  [`ci.yml`](.github/workflows/ci.yml) (warn).
- **GitHub security** (when `gh` is authenticated) — Dependabot vulnerability alerts + security
  updates, and secret scanning on public repos (warn). Fleet-wide feature flags and security
  settings are defined in [`config/github-repo-baseline.json`](config/github-repo-baseline.json);
  check/apply with [`scripts/sync-github-settings.sh`](scripts/sync-github-settings.sh) (see
  [`doc/github-repo-settings.md`](doc/github-repo-settings.md)).

Run locally against a checkout:

```bash
scripts/check-repo-compliance.sh /path/to/repo
```

## Repository catalog

[`structure/repos.json`](structure/repos.json) lists every OpenPhysics repository with metadata
(`displayName`, `type`, `language`, `description`, optional `deployedUrl` / `githubTopics` /
`shortDescription`, `status`). Schema: [`structure/repos.schema.json`](structure/repos.schema.json)
(validated by [`scripts/check-repos-catalog.sh`](scripts/check-repos-catalog.sh)). The compliance
workflow and the catalog scripts consume this file. See [`scripts/README.md`](scripts/README.md)
for the full tooling reference:

```bash
scripts/check-repos-catalog.sh
scripts/parse-repos.sh names --type library
scripts/list-repos.sh --json
scripts/sync-github-metadata.sh --dry-run
scripts/sync-github-settings.sh --check
```

**Adding a repo**: see [`doc/add-repo.md`](doc/add-repo.md) — it's a `structure/repos.json` edit
plus a few sync-script runs, no code generation involved.

Scripts assume the `relay` repo lives beside member repos in a shared workspace; set
`FLEET_WORKSPACE` or pass `--catalog /path/to/repos.json` if your checkout differs.

## Fleet operations

Cross-repo automation, all driven from the catalog:

- **Batch changes** — [`scripts/fleet-exec.sh`](scripts/fleet-exec.sh) clones each selected
  repo, runs a command, and (with `--apply`) opens one PR per repo. Dry-run by default. The
  [`fleet-exec.yml`](.github/workflows/fleet-exec.yml) workflow exposes it as a manual dispatch
  (e.g. bump a shared dependency, run `npm run fix`, apply a codemod). Opening PRs in other
  repos needs a `FLEET_PAT` secret with write access — the default `GITHUB_TOKEN` is scoped to
  relay only. Setup steps (fine-grained PAT or GitHub App): [`doc/fleet-auth.md`](doc/fleet-auth.md).
- **Health report** — [`fleet-health.yml`](.github/workflows/fleet-health.yml) runs weekly,
  fanning out one matrix job per active npm repo (download cache reused across runs) to run
  lint, type-check, build, and test, then publishing a pass/fail table to the job summary.
  Read-only; surfaces a repo broken by a shared-workflow or dependency change.
- **Compliance audit** — [`shared-compliance-check.yml`](.github/workflows/shared-compliance-check.yml)
  audits README/CI/Dependabot wiring across the org, fanning out one matrix job per repo and
  aggregating a single pass/fail table (see above).
- **Everyday git fan-out** — [`doc/fleet-git.md`](doc/fleet-git.md) is a cheat sheet for running
  git across your local checkouts (`pull all`, `push all`, `status all`), built on
  `parse-repos.sh paths`. Use it for ad-hoc local work; use `fleet-exec.sh` to land the same
  change as PRs.
- **Off-GitHub backup** — [`scripts/sync-gitlab-mirror.sh`](scripts/sync-gitlab-mirror.sh) pushes
  every catalog repo's git history (branches, tags, commits — no issues, PRs, CI, or Pages) into a
  GitLab group. The same command does the first import and each later sync;
  [`gitlab-mirror.yml`](.github/workflows/gitlab-mirror.yml) runs it daily once a `GITLAB_TOKEN`
  secret exists, and `--check` verifies the backup is current. Setup and restore procedure:
  [`doc/gitlab-mirror.md`](doc/gitlab-mirror.md).

## Node version

The default Node version for the npm side of the fleet is **`"24"`**, declared in every relay
workflow that runs `setup-node` — bump them together:

- [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — `node-version` input default
- [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) — `node-version` input default
- [`.github/workflows/fleet-health.yml`](.github/workflows/fleet-health.yml) — `setup-node` step
- [`.github/workflows/fleet-exec.yml`](.github/workflows/fleet-exec.yml) — `setup-node` step

[`scripts/check-node-version.sh`](scripts/check-node-version.sh) enforces that they stay in
sync (run in CI by [`relay-selfcheck.yml`](.github/workflows/relay-selfcheck.yml)), so a half-done
bump fails fast instead of drifting silently. When sibling member checkouts are present (local
OpenPhysics workspace), it also checks each npm repo's `package.json` against the same major —
existing repos onboarded before this baseline was set may still show drift; that's a real gap to
close per repo, not a bug in the check.

[`scripts/check-repo-compliance.sh`](scripts/check-repo-compliance.sh) warns (rather than fails) a
repo whose `engines.node` doesn't match. Prefer no `.nvmrc` / `.node-version`; if present, the
major should match the fleet.
