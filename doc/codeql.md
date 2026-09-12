# CodeQL across the fleet

Every JavaScript/TypeScript repo calls the reusable workflow
[`shared-codeql.yml`](../.github/workflows/shared-codeql.yml) from their `ci.yml`:

```yaml
codeql:
  uses: OpenPhysics/Relay/.github/workflows/shared-codeql.yml@main
```

The shared job analyzes JavaScript/TypeScript with the
`security-extended` and `security-and-quality` query suites.

## Path exclusions

None are configured by default. If a repo has local offline tooling that
legitimately downloads assets to disk (and trips a rule like
`js/http-to-file-access` as a false positive), add a `paths-ignore` entry to
the shared workflow's CodeQL `config:` block rather than dismissing the alert
per repo — prefer one org-wide exclude over per-repo dismissals.
