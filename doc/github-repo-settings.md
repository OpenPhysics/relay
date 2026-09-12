# GitHub repository settings baseline

Canonical settings for every OpenPhysics catalog repo. New GitHub repos inherit
defaults (wiki on, Projects on, security features off) — do **not**
reverse-engineer a mature repo by hand. Use the machine-readable baseline and
the apply script in this repo instead.

| Artifact | Role |
|---|---|
| [`config/github-repo-baseline.json`](../config/github-repo-baseline.json) | Source of truth (feature flags + security + Pages) |
| [`scripts/sync-github-settings.sh`](../scripts/sync-github-settings.sh) | `--check` drift / `--apply` via GitHub API |
| [`scripts/sync-github-metadata.sh`](../scripts/sync-github-metadata.sh) | Description + homepage + topics from `structure/repos.json` |

## Quick use

```bash
cd relay

# After adding a new repo to the catalog (or anytime you suspect drift)
scripts/sync-github-settings.sh --check --repo MyNewRepo
scripts/sync-github-settings.sh --apply --repo MyNewRepo

# Description + website + topics from the catalog
scripts/sync-github-metadata.sh --repo MyNewRepo

# Every catalog repo
scripts/sync-github-settings.sh --check
scripts/sync-github-settings.sh --apply

# Just the libraries
scripts/sync-github-settings.sh --check --type library
```

Requires `gh` authenticated with access to update repository settings (`repo` scope).

## What the baseline requires

### Repository features

| Setting | Value |
|---|---|
| Issues | on |
| Wiki | **off** |
| Projects | **off** |
| Downloads | off |
| Default branch | `main` |
| Squash / merge commit / rebase | all allowed (fleet defaults) |
| Auto-merge / update branch / delete branch on merge | off |
| Web commit signoff | off |

### Security (public repos)

| Setting | Value |
|---|---|
| Dependabot vulnerability alerts | on |
| Dependabot security updates | on |
| Secret scanning | on |
| Secret scanning push protection | on |
| Non-provider patterns / validity checks | off (matches fleet majority) |
| Private vulnerability reporting | on (see [`SECURITY.md`](../SECURITY.md)) |

### Pages

For repos with GitHub Pages (a `deployedUrl` / homepage):

| Setting | Value |
|---|---|
| Build type | `workflow` (Source → GitHub Actions) |

Code scanning **default setup** stays not-configured: repos use Relay's reusable
[`shared-codeql.yml`](../.github/workflows/shared-codeql.yml) instead.

### Out of scope here

- Branch protection (org/policy)
- Contents of `.github/dependabot.yml` — [`sync-dependabot.sh`](../scripts/sync-dependabot.sh)

## When to run

1. **New repo** — right after it's added to `structure/repos.json`
   (also listed in [`add-repo.md`](add-repo.md)).
2. **Suspected drift** — especially brand-new org repos that still have GitHub defaults.
3. **Periodic audit** — `scripts/sync-github-settings.sh --check`.

## Private repositories

Private catalog repos still get vulnerability alerts and feature flags
(wiki/projects off). Secret scanning and private vulnerability reporting may be unavailable
without GitHub Advanced Security; the checker treats those as out of scope for private repos.
