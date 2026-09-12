# OpenPhysics org scripts

Utilities for reading [`structure/repos.json`](../structure/repos.json) and operating on
OpenPhysics repositories. These scripts are intended for local use and for AI agents working in
the workspace checkout.

## Prerequisites

- [`jq`](https://jqlang.org/)
- [`gh`](https://cli.github.com/) for GitHub sync commands
- `python3` (with `jsonschema` if you want full catalog schema validation, and for
  `sync-github-settings.sh`)
- Node.js + `npm install` (in the repo root) to run the bats test suite

## Quick reference

| Script | Purpose |
|---|---|
| [`parse-repos.sh`](parse-repos.sh) | Core parser/CLI for `repos.json` |
| [`list-repos.sh`](list-repos.sh) | Human-friendly listing wrapper |
| [`check-repos-catalog.sh`](check-repos-catalog.sh) | Validate `repos.json` against `structure/repos.schema.json` + fleet invariants |
| [`check-uncataloged.sh`](check-uncataloged.sh) | Detect org repos on GitHub that are missing from `repos.json` (catches un-onboarded repos) |
| [`clone-fleet.sh`](clone-fleet.sh) | Clone/update every catalog repo into the workspace as a sibling |
| [`fleet`](fleet) | Run a git command across every local checkout (`fleet push`, `fleet status -s`, …) |
| [`fleet-exec.sh`](fleet-exec.sh) | Run a command across many repos and open one PR each |
| [`../doc/fleet-git.md`](../doc/fleet-git.md) | Cheat sheet: everyday git across local checkouts (`pull`/`push`/`status` all) |
| [`sync-gitlab-mirror.sh`](sync-gitlab-mirror.sh) | Mirror every catalog repo's git history to a GitLab group (off-GitHub backup) |
| [`../doc/gitlab-mirror.md`](../doc/gitlab-mirror.md) | GitLab backup: setup, initial import, periodic sync, restore |
| [`sync-github-metadata.sh`](sync-github-metadata.sh) | Push description + website + topics to GitHub |
| [`sync-github-settings.sh`](sync-github-settings.sh) | Check/apply GitHub repo settings baseline (security + feature flags) |
| [`../doc/github-repo-settings.md`](../doc/github-repo-settings.md) | Documented GitHub settings baseline |
| [`lib/repos.sh`](lib/repos.sh) | Bash helper functions for other scripts |
| [`lib/rewrite_org_refs.py`](lib/rewrite_org_refs.py) | Rewrite org-qualified references in a repo (used by `sync-repo-docs.sh`) |
| [`sync-repo-docs.sh`](sync-repo-docs.sh) | Rewrite org-qualified prose/workflow references (CI badges, LICENSE links, `uses:` calls, …) across member repos |
| [`check-repo-compliance.sh`](check-repo-compliance.sh) | README/license/CI/Dependabot/Node-pin compliance for one repo |
| [`check-node-version.sh`](check-node-version.sh) | Assert fleet Node major agrees across workflows; with sibling checkouts, also engines.node |
| [`sync-dependabot.sh`](sync-dependabot.sh) | Copy Dependabot configs from `config/` to catalog npm/pip repos (by `language`) |

## parse-repos.sh

Primary entry point for agents. Reads `structure/repos.json` and adds computed fields:

- `githubHomepage` — `deployedUrl` if set, else `<pagesBase>/<name>` when the catalog sets a
  fleet-wide `pagesBase`, else `null`
- `localPath` — sibling directory in the workspace checkout
- `localExists` — whether that directory is present locally

```bash
# All repository names
scripts/parse-repos.sh names

# Library repos only
scripts/parse-repos.sh names --type library

# Full JSON with computed fields
scripts/parse-repos.sh list --format json --type library

# One repo
scripts/parse-repos.sh get pycd48

# Local checkout paths for repos that exist on disk
scripts/parse-repos.sh paths --type library --require-local

# Run a command per repo (env: REPO_NAME, REPO_DISPLAY_NAME, REPO_TYPE, REPO_STATUS, REPO_HOMEPAGE, REPO_PATH, ...)
scripts/parse-repos.sh for-each --type library -- \
  echo "$REPO_NAME ($REPO_TYPE) -> $REPO_HOMEPAGE"

# Catalog summary
scripts/parse-repos.sh summary
```

Filters:

- `--type app|library|tool|config|template`
- `--status active|template|draft|wip|archived`

## clone-fleet.sh

Populate the workspace from the catalog: clone every selected repo as a sibling directory
beside `Relay`. `repos.json` is the single source of truth — a repo appears here the moment
it is added to the catalog. Re-runnable and safe: repos already on disk are skipped unless
`--update` is given (which `git pull --ff-only`s them).

```bash
# Clone whatever is missing into the workspace
scripts/clone-fleet.sh

# Only the libraries, and fast-forward any already present
scripts/clone-fleet.sh --type library --update

# Preview the plan, change nothing (HTTPS instead of SSH)
scripts/clone-fleet.sh --dry-run --https
```

Reuses the same catalog filters as `parse-repos.sh` (`--type`, `--status`, `--only NAME`,
`--skip NAME`). Clones over SSH by default; `--https` for token/anonymous use.

## fleet

Run any git command across every catalog repo already checked out locally:

```bash
# put on PATH once (if ~/.local/bin is already there)
ln -sfn ~/OpenPhysics/Relay/scripts/fleet ~/.local/bin/fleet

fleet push
fleet pull --ff-only
fleet status -s
fleet --type library log -1 --oneline
```

Same catalog filters as `parse-repos.sh`. Full cheat sheet: [`doc/fleet-git.md`](../doc/fleet-git.md).

## fleet-exec.sh

Fan a change out across the org: clone each selected repo, run a command in it, and
— with `--apply` — push a branch and open one PR per repo. **Dry-run by default** (prints
a diffstat per repo and opens nothing). Reuses the same catalog filters as `parse-repos.sh`.

```bash
# Preview bumping a dependency across every library (no PRs):
scripts/fleet-exec.sh --type library -- npm pkg set devDependencies.eslint=^9.0.0

# Apply a Biome autofix across all libraries and open one PR each:
scripts/fleet-exec.sh --type library --apply --install \
  --branch chore/biome-fix --title "chore: biome autofix" -- npm run fix
```

Key options: `--apply` (push + open PRs), `--install` (`npm install` before the command,
needed for lint/build codemods), `--branch`, `--title`, `--label`, `--skip NAME`, `--keep`.

Pushing and opening PRs needs a token with **write access to the target repos** — your local
`gh auth`, or an org PAT / GitHub App token as `GH_TOKEN`. The default `GITHUB_TOKEN` only
reaches the repo running a workflow, so the [`fleet-exec.yml`](../.github/workflows/fleet-exec.yml)
dispatch wrapper reads a `FLEET_PAT` secret for `apply=true`.

## sync-gitlab-mirror.sh

Keep an off-GitHub backup of the fleet: push every catalog repo's **git data** — branches,
tags, commits — into a GitLab group. Issues, merge requests, CI, and Pages are not copied,
and are disabled on the projects this script creates. Same command for the first import and
for every later sync; a bare mirror cached per repo makes repeat runs incremental.

```bash
export GITLAB_TOKEN=glpat-…            # api + write_repository scopes

scripts/sync-gitlab-mirror.sh --dry-run        # show the plan, change nothing
scripts/sync-gitlab-mirror.sh                  # initial import of the whole fleet
scripts/sync-gitlab-mirror.sh --type library   # later syncs, libraries only
scripts/sync-gitlab-mirror.sh --check          # is the backup current? (read-only)
```

Key options: `--group`/`--host` (default `OpenPhysics` on `https://gitlab.com`),
`--visibility private|internal|public` (default private), `--work-dir`, `--fresh`,
`--no-prune`, plus the usual catalog filters. `.github` is mirrored as `dot-github`
(GitLab paths cannot start with a dot).

Runs daily from [`gitlab-mirror.yml`](../.github/workflows/gitlab-mirror.yml) once a
`GITLAB_TOKEN` secret exists on Relay. Setup, verification, and the restore procedure:
[`../doc/gitlab-mirror.md`](../doc/gitlab-mirror.md).

## sync-github-metadata.sh

Updates GitHub **Description**, **Website**, and **topics** from `repos.json`:

```bash
scripts/sync-github-metadata.sh --dry-run
scripts/sync-github-metadata.sh
scripts/sync-github-metadata.sh --repo pycd48
scripts/sync-github-metadata.sh --type library
```

Topics are a kebab-case slug per `language` entry, plus any `githubTopics` extras (catalog is
source of truth; the topic set is replaced). A row with neither leaves topics untouched.

GitHub **Description** prefers `shortDescription` when set, otherwise
`description`. Descriptions longer than 350 characters are truncated with a
warning (GitHub's API limit). Topics are capped at 20 (GitHub's limit).

## sync-github-settings.sh

Check or apply the canonical GitHub **repository settings** baseline
([`config/github-repo-baseline.json`](../config/github-repo-baseline.json)): wiki/Projects off,
Dependabot alerts + security updates, secret scanning + push protection, private vulnerability
reporting, and Pages `build_type=workflow`. Full write-up:
[`../doc/github-repo-settings.md`](../doc/github-repo-settings.md).

```bash
scripts/sync-github-settings.sh --check                  # every catalog repo; exit 1 on drift
scripts/sync-github-settings.sh --apply --repo MyNewRepo  # fix one repo
scripts/sync-github-settings.sh --apply                   # every catalog repo
scripts/sync-github-settings.sh --apply --dry-run         # show planned fixes
```

Use this after adding a new repo to the catalog (GitHub defaults diverge from the fleet)
instead of inspecting a mature repo by hand.

## sync-repo-docs.sh

Rewrites org-qualified references (CI badges, LICENSE/CONTRIBUTING links, `package.json`
repository URLs, `uses:` calls into Relay, …) in member repos to match the catalog's
`organization` / `pagesBase`. Useful after an org rename — a one-field catalog edit followed by
one run of this script.

```bash
scripts/sync-repo-docs.sh --from OldOrg --dry-run    # preview every change
scripts/sync-repo-docs.sh --from OldOrg              # apply in place
```

Writes files only — committing, pushing, and opening PRs is left to you or to `fleet-exec.sh`.

## Self-check scripts

Run by [`relay-selfcheck.yml`](../.github/workflows/relay-selfcheck.yml) on every PR or `main`
push that touches `scripts/`, `structure/`, or Relay's own `.github/workflows`/`.github/actions`,
and runnable locally:

```bash
scripts/check-repos-catalog.sh   # repos.json matches its JSON Schema + fleet invariants
scripts/check-node-version.sh    # all setup-node workflows declare the same Node version
scripts/check-uncataloged.sh     # every org repo on GitHub is in the catalog
```

## check-uncataloged.sh

Lists repos under the GitHub org that are missing from `structure/repos.json`, so a
forgotten onboarding can't stay hidden. Intentional non-members are kept in an in-script
allowlist, extendable via `UNCATALOGED_ALLOWLIST` or `structure/uncataloged-allowlist.txt`.
Requires `gh` (authed) and `jq`; exits 1 if any uncataloged repo is found.

## Bash helpers

Source from other scripts:

```bash
source "$(dirname "$0")/lib/repos.sh"
repos_names | while read -r repo; do
  echo "$repo"
done
```

Or call the CLI directly:

```bash
scripts/parse-repos.sh names --type library
```

## Workspace layout

Scripts assume the orchestration `Relay` repo lives beside member repos:

```
OpenPhysics/
  Relay/            ← this repo
  pyro/
  pycd48/
  jscd48-tmp/
  tscd48-tmp/
  ...
```

If your checkout differs, set `FLEET_WORKSPACE` or pass `--catalog /path/to/repos.json`.
