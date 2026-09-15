# Adding a repo to the catalog

Checklist for onboarding a new (or pre-existing) OpenPhysics repo into the fleet
tooling. `structure/repos.json` is the single source of truth — nothing here
requires editing a script.

1. **Add a catalog entry.** Append an object to `structure/repos.json` with at
   least `name`, `displayName`, `type` (`app` | `library` | `tool` | `config` |
   `template`), `language`, `description`, and `status`. Validate it:

   ```bash
   scripts/check-repos-catalog.sh
   ```

2. **Clone it into the workspace** (if not already there):

   ```bash
   scripts/clone-fleet.sh --only <Name>
   ```

3. **Wire shared CI.** In the repo's `.github/workflows/ci.yml`, call relay's
   reusable workflows (see the [README](../README.md#shared-ci) for the exact
   snippet). Add `.github/dependabot.yml` from
   [`config/dependabot-npm.yml`](../config/dependabot-npm.yml) or
   [`config/dependabot-pip.yml`](../config/dependabot-pip.yml) — or run:

   ```bash
   scripts/sync-dependabot.sh <Name>
   ```

4. **Apply the GitHub settings baseline** (see
   [`doc/github-repo-settings.md`](github-repo-settings.md)):

   ```bash
   scripts/sync-github-settings.sh --apply --repo <Name>
   scripts/sync-github-metadata.sh --repo <Name>
   ```

5. **Check compliance:**

   ```bash
   scripts/check-repo-compliance.sh ../<Name>
   ```

6. **Confirm it's no longer flagged as uncataloged:**

   ```bash
   scripts/check-uncataloged.sh
   ```
