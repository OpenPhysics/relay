# Fleet authentication

Cross-repo **writes** — pushing branches and opening PRs in other OpenPhysics repos from
[`fleet-exec.yml`](../.github/workflows/fleet-exec.yml) / [`scripts/fleet-exec.sh`](../scripts/fleet-exec.sh)
with `--apply` — need a token with write access to **those** repos.

The workflow's default `GITHUB_TOKEN` is scoped to Relay only, so it can clone public repos
(enough for dry-runs and the read-only [`fleet-health.yml`](../.github/workflows/fleet-health.yml)
and compliance audits) but **cannot** push to or open PRs in the sim repos. For that, supply a
broader token.

```
fleet-exec --apply  ─uses→  GH_TOKEN  ─prefers→  secrets.FLEET_PAT  ─else→  github.token (Relay-only, read)
```

You have two options. A **fine-grained PAT** is the quickest; a **GitHub App** is the more robust
choice for ongoing org-wide automation (short-lived tokens, not tied to a person).

---

## Option A — Fine-grained personal access token (quickest)

1. Create the token at **GitHub → Settings → Developer settings → Fine-grained tokens → Generate new token**
   (<https://github.com/settings/personal-access-tokens>).
2. Set:
   - **Resource owner**: `OpenPhysics` (not your personal account).
   - **Repository access**: *All repositories*, or *Only select repositories* and pick the sim
     repos listed in [`structure/repos.json`](../structure/repos.json).
   - **Repository permissions**:
     - **Contents** → **Read and write** (clone + push branches)
     - **Pull requests** → **Read and write** (open PRs)
     - **Metadata** → Read-only (selected automatically)
     - **Workflows** → **Read and write** *only* if a fleet change will edit files under
       `.github/workflows/` in the target repos (GitHub rejects workflow edits otherwise).
   - **Expiration**: pick a finite window (e.g. 90 days) and set a rotation reminder.
3. Add it as a Relay repository secret named **`FLEET_PAT`**:

   ```bash
   gh secret set FLEET_PAT --repo OpenPhysics/relay
   # paste the token when prompted
   ```

   Or via the UI: **Relay → Settings → Secrets and variables → Actions → New repository secret**,
   name `FLEET_PAT`.

That's it — `fleet-exec.yml` already reads `secrets.FLEET_PAT`. Org PAT policies must allow
fine-grained tokens (**Org → Settings → Personal access tokens**); an org admin may need to
approve the token before it works.

---

## Option B — GitHub App (recommended for ongoing automation)

A GitHub App mints a short-lived installation token per run, isn't tied to anyone's account, and
scopes cleanly to the installed repos.

1. **Create the app**: **Org → Settings → Developer settings → GitHub Apps → New GitHub App**.
   - **Permissions**: Contents → Read and write; Pull requests → Read and write
     (+ Workflows → Read and write only if editing workflow files).
   - No webhook needed.
2. **Install** the app on the OpenPhysics repos you want to target.
3. Generate a **private key** and store two secrets on Relay:

   ```bash
   gh secret set FLEET_APP_ID      --repo OpenPhysics/relay   # the app's numeric ID
   gh secret set FLEET_APP_PRIVATE_KEY --repo OpenPhysics/relay < path/to/app-private-key.pem
   ```
4. Mint a token in the workflow and hand it to `fleet-exec` as `GH_TOKEN`. Add this step before
   "Run fleet-exec" in [`fleet-exec.yml`](../.github/workflows/fleet-exec.yml):

   ```yaml
   - name: Mint installation token
     id: app-token
     uses: actions/create-github-app-token@v2
     with:
       app-id: ${{ secrets.FLEET_APP_ID }}
       private-key: ${{ secrets.FLEET_APP_PRIVATE_KEY }}
       owner: OpenPhysics
   ```

   then change the `GH_TOKEN` line to:

   ```yaml
   GH_TOKEN: ${{ steps.app-token.outputs.token || secrets.FLEET_PAT || github.token }}
   ```

---

## Verifying

1. **Preflight the token** (read-only, no side effects). Run the **Fleet Exec** workflow with
   `check_auth` checked to confirm `FLEET_PAT` can push to the targeted repos — it queries each
   repo's push permission via the API and opens nothing:

   ```bash
   gh workflow run fleet-exec.yml --repo OpenPhysics/relay -f target=library -f check_auth=true
   # or a single repo: -f only=pycd48 -f check_auth=true
   # locally: scripts/fleet-exec.sh --type library --check-auth
   ```

   A run reporting `Auth preflight as: <token owner>` and `N/N writable` confirms the secret works.
2. **Dry-run** a real change (prints diffstats, opens nothing):

   ```bash
   scripts/fleet-exec.sh --type library -- npm pkg set devDependencies.eslint=^9.0.0
   ```
3. **Apply to one repo** as a smoke test with `--only` (or the `only` workflow input), then re-run
   with `apply` enabled. Verify one PR opens before scaling up.

## Editing Relay's own workflows

Pushing changes to files under `.github/workflows/` in **Relay itself** (e.g. editing
`fleet-exec.yml`) requires your local `gh`/git token to carry the **`workflow`** OAuth scope —
GitHub rejects the push otherwise (`refusing to allow an OAuth App to … workflow … without
workflow scope`). Add it once:

```bash
gh auth refresh -h github.com -s workflow
```

This is separate from `FLEET_PAT` (which governs writes to the *target* sim repos); it only affects
pushing workflow edits to Relay from your machine.

## Safety notes

- Prefer **fine-grained** tokens / **App** installs over classic PATs — grant only Contents and
  Pull requests, never admin.
- `fleet-exec` is **dry-run by default**; `--apply` (or `apply=true`) is the only thing that writes.
- Add a `--label` so fleet PRs are easy to find, triage, and bulk-close if needed.
- Rotate the PAT on its expiry; App tokens expire automatically each run.
