# GitLab backup mirror

The fleet lives on GitHub. This is the off-GitHub copy: every repository in
[`structure/repos.json`](../structure/repos.json) pushed into a GitLab group so the history
survives an account lockout, an accidental deletion, or GitHub itself having a bad week.

[`scripts/sync-gitlab-mirror.sh`](../scripts/sync-gitlab-mirror.sh) does the initial import **and**
every later sync — same command, run again.

## What is (and is not) copied

| Copied | Not copied |
|---|---|
| All branches (`refs/heads/*`) | Issues, merge/pull requests, reviews |
| All tags (`refs/tags/*`) | Releases and release assets |
| Every commit those refs reach | Actions workflows and CI history |
| The default-branch setting | GitHub Pages deployments |

This is a **git backup**, not a second home for the project. The mirror is only as good as
`git` data: work that lives in GitHub's database (issue threads, PR discussion) is not in it.
Projects the script creates have issues, merge requests, CI, wiki, snippets, packages, and Pages
switched off, so nobody mistakes the copy for the original. A repo's Pages site will not render
from GitLab — GitLab Pages needs its own `.gitlab-ci.yml` job, which the mirror deliberately does
not add.

Direction is GitHub → GitLab, driven from our side. GitLab can pull-mirror an external repo on a
schedule by itself, but that is a paid feature; pushing from here works on the free tier and keeps
the schedule visible in relay.

## One-time setup

### 1. The GitLab group

Create a group (e.g. `OpenPhysics`) at <https://gitlab.com/groups/new>. The group path is
case-sensitive and is what `--group` expects.

Then set **Group → Settings → Repository → Initial default branch protection** to
**Not protected**. GitLab otherwise protects the default branch the first time it is pushed, and a
protected branch rejects the two things a mirror must be able to do: force-update a branch whose
history was rewritten upstream, and delete a branch that was deleted upstream. (The script also
clears protection per project before pushing, so this setting is belt-and-braces.)

### 2. A token

A **personal access token** works everywhere: <https://gitlab.com/-/user_settings/personal_access_tokens>
with the **`api`** and **`write_repository`** scopes. If your plan offers group access tokens, a
group token on `OpenPhysics` with the **Maintainer** role is the tidier choice — it is not tied to
a person.

```bash
export GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx
```

The script never writes the token to disk or passes it on a command line: curl reads it from a
`0600` temp config, and git receives it as an `Authorization` header through `GIT_CONFIG_*`
environment variables. Nothing is baked into the cached mirrors' remotes.

### 3. Visibility

New projects are created **private** — a backup does not need an audience. Pass
`--visibility public` (or `GITLAB_VISIBILITY=public`) if you would rather the mirror be browsable.

## Initial import of the fleet

```bash
# See what would happen — creates nothing, pushes nothing
scripts/sync-gitlab-mirror.sh --dry-run

# Do it
scripts/sync-gitlab-mirror.sh
```

Each repo is cloned into a bare mirror under `~/.cache/openphysics/gitlab-mirror/` and pushed. The
first run is the slow one (full clones); later runs transfer only new objects.

Per repo the output is one of `created`, `pushed N ref update(s)`, or `up to date`, and the run
ends with a summary. Exit status is non-zero if any repo failed.

## Periodic sync

Re-run the same command — locally, or from
[`.github/workflows/gitlab-mirror.yml`](../.github/workflows/gitlab-mirror.yml), which runs it
daily at 04:00 UTC and on manual dispatch. For the workflow, add the token as a relay repository
secret:

```bash
gh secret set GITLAB_TOKEN --repo OpenPhysics/relay
# paste the token when prompted
```

Without that secret the workflow logs a notice and exits cleanly, so it is harmless until you set
it up. Run it by hand with:

```bash
gh workflow run gitlab-mirror.yml --repo OpenPhysics/relay
gh workflow run gitlab-mirror.yml --repo OpenPhysics/relay -f mode=check
gh workflow run gitlab-mirror.yml --repo OpenPhysics/relay -f only=pycd48
```

Or from a local cron / launchd job:

```cron
17 4 * * *  GITLAB_TOKEN=glpat-… /home/you/OpenPhysics/relay/scripts/sync-gitlab-mirror.sh >> /tmp/gitlab-mirror.log 2>&1
```

## Verifying the backup

`--check` compares the ref lists on both sides with `git ls-remote` — no clones, no writes — and
exits non-zero if anything is stale or missing:

```bash
scripts/sync-gitlab-mirror.sh --check
```

```
==== pycd48 -> OpenPhysics/pycd48 ====
  in sync (14 ref(s))
==== pyro -> OpenPhysics/pyro ====
  STALE — 2 ref(s) differ from GitHub
----
Summary: 5 repo(s) — 4 in sync, 1 stale, 0 missing, 0 unreadable.
```

## Restoring from the mirror

The mirror is a normal git repo, so recovery is a clone and a push:

```bash
git clone --mirror https://gitlab.com/OpenPhysics/pycd48.git
cd pycd48.git
git push --mirror git@github.com:OpenPhysics/pycd48.git   # into a fresh, empty repo
```

Then re-run the fleet onboarding for the restored repo (settings, metadata, Dependabot):
see [`doc/github-repo-settings.md`](github-repo-settings.md) and
[`scripts/sync-github-settings.sh`](../scripts/sync-github-settings.sh).

## Notes and edge cases

- **`.github` → `dot-github`.** GitLab project paths may not start with a dot, so the org's
  `.github` repo is mirrored as `dot-github`. Everything else keeps its name.
- **Pull-request refs are skipped.** GitHub advertises `refs/pull/*`; the mirror fetches only
  heads and tags, so those never land on GitLab.
- **Deletions propagate.** A branch or tag deleted on GitHub is deleted on the mirror. Use
  `--no-prune` for a hoard-everything backup instead of a true mirror.
- **The mirror is one-way.** Anything committed directly on GitLab is overwritten on the next
  sync. Keep GitHub the source of truth.
- **Cache location.** `--work-dir` (default `~/.cache/openphysics/gitlab-mirror`) holds the bare
  mirrors; deleting it costs nothing but a slow next run. `--fresh` re-clones one anyway.
- **Filters.** The same catalog filters as the other fleet scripts: `--type`,
  `--status`, `--only NAME`, `--skip NAME`.
