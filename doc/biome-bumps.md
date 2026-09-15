# Biome dependency bumps

**Rule:** whenever `@biomejs/biome` is bumped (Dependabot PR or manual), also update
`biome.json`'s `$schema` to the **same version**. Dependabot only touches
`package.json` / the lockfile — it will not sync the schema URL.

## Why

Member repos pin Biome like:

```json
"@biomejs/biome": "^2.5.13"
```

and point the config schema at a matching URL:

```json
{
  "$schema": "https://biomejs.dev/schemas/2.5.13/schema.json"
}
```

If the package moves to `2.5.13` but `$schema` stays on `2.5.11` / `2.5.12`, editors and
`biome check` can warn or disagree with the installed CLI. We have hit this repeatedly on
fleet Dependabot PRs (`pyro`, `tscd48-tmp`, …).

## Checklist when reviewing a Biome bump

1. Confirm the new `@biomejs/biome` version in `package.json` (and lockfile).
2. Open `biome.json` (repo root). Set `$schema` to:

   `https://biomejs.dev/schemas/<exact-version>/schema.json`

   Use the resolved package version (e.g. `2.5.13`), not a floating range.
3. Push that one-line change onto the Dependabot branch if the PR is still open:

   ```bash
   branch=dependabot/npm_and_yarn/development-dependencies-<hash>
   tmp=/tmp/biome-schema-<repo>
   rm -rf "$tmp"
   git clone --depth 1 -b "$branch" "git@github.com:OpenPhysics/<repo>.git" "$tmp"
   cd "$tmp"
   # replace any existing schemas/X.Y.Z/schema.json with the new version
   perl -i -pe 's|schemas/[0-9]+\.[0-9]+\.[0-9]+/schema\.json|schemas/2.5.13/schema.json|g' biome.json
   git add biome.json
   git commit -m "chore: sync biome.json schema with @biomejs/biome 2.5.13"
   git push
   ```

4. Re-approve the PR if the new commit dismissed a prior review.
5. Run CI / `biome check .` as usual.

## Fleet / agents

When triaging Dependabot “development-dependencies” group PRs:

- If the changelog includes `@biomejs/biome`, treat schema sync as **required**, not optional.
- A green CI build does **not** prove the schema matches — still check `biome.json`.
- Prefer fixing on the Dependabot branch over opening a separate PR, so one merge lands
  package + schema together.

## Related

- Dependabot templates: [`config/dependabot-npm.yml`](../config/dependabot-npm.yml)
- Sync templates into member repos: [`scripts/sync-dependabot.sh`](../scripts/sync-dependabot.sh)
- Fan-out fixes across repos: [`scripts/fleet-exec.sh`](../scripts/fleet-exec.sh) /
  [`doc/fleet-git.md`](fleet-git.md)
