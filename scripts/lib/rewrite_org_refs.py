"""Rewrite org-qualified references inside one member repo checkout.

Driven by sync-repo-docs.sh. Reads its inputs from the environment so the shell
side stays readable:

  ORG            target organization login
  PAGES_BASE     target Pages base, e.g. https://org.github.io
  REPO, DIR      the repo being rewritten and its checkout path
  FROM_OWNERS    newline-separated owners to rewrite FROM
  CATALOG_REPOS  newline-separated fleet repo names (the collision guard)
  DRY_RUN        "1" to report without writing

Exits 10 when something changed (or would change), 0 when already in sync.
"""

import os
import re
import subprocess
import sys

ORG = os.environ["ORG"]
PAGES_BASE = os.environ["PAGES_BASE"].rstrip("/")
REPO = os.environ["REPO"]
DIR = os.environ["DIR"]
DRY_RUN = os.environ.get("DRY_RUN") == "1"
FROM_OWNERS = [o for o in os.environ["FROM_OWNERS"].split("\n") if o]
CATALOG_REPOS = [r for r in os.environ["CATALOG_REPOS"].split("\n") if r]

SKIP_DIRS = {".git", "node_modules", "dist", "coverage", ".venv", ".mypy_cache",
             "build", ".next", "__pycache__"}
TEXT_SUFFIXES = {".md", ".json", ".yml", ".yaml", ".ts", ".tsx", ".js", ".mjs",
                 ".cjs", ".html", ".sh", ".txt", ".toml", ".css"}
# Extensionless files worth rewriting.
TEXT_NAMES = {"CODEOWNERS", "Dockerfile", "LICENSE", "LICENSE-MIT", "NOTICE"}

owners = "|".join(re.escape(o) for o in FROM_OWNERS)
repos = "|".join(re.escape(r) for r in CATALOG_REPOS)

# A fleet repo reference is only rewritten when BOTH the owner is one we were
# told to rewrite AND the repo is a known fleet repo. That keeps third-party
# links (github.com/some-other-org/..., github.com/someone/some-repo) untouched.
RULES = [
    # https://github.com/OWNER/FleetRepo...
    (re.compile(r"(https://github\.com/)(?:%s)(/(?:%s)\b)" % (owners, repos)),
     lambda m: m.group(1) + ORG + m.group(2)),
    # git@github.com:OWNER/FleetRepo...
    (re.compile(r"(git@github\.com:)(?:%s)(/(?:%s)\b)" % (owners, repos)),
     lambda m: m.group(1) + ORG + m.group(2)),
    # Bare OWNER/FleetRepo - covers `uses: Org/relay/.github/workflows/...`
    # and CODEOWNERS-style references.
    (re.compile(r"\b(?:%s)(/(?:%s)\b)" % (owners, repos)),
     lambda m: ORG + m.group(1)),
]

# Pages hosts belonging to the owners we are rewriting from.
for _owner in FROM_OWNERS:
    RULES.append((
        re.compile(r"https://%s\.github\.io" % re.escape(_owner), re.IGNORECASE),
        lambda m: PAGES_BASE,
    ))

# Whole-word bare org mentions in prose ("the <Org> fleet").
BARE = re.compile(r"\b(?:%s)\b" % owners)

# The lowercase form shows up in cache paths (~/.cache/org/...), npm package
# names, plugin keywords and Pages hosts written as link text. It has to map to
# the lowercase target rather than the CamelCase login.
BARE_LOWER = re.compile(r"\b(?:%s)\b" % "|".join(re.escape(o.lower()) for o in FROM_OWNERS))

# GitHub resolves ../../ against the repo serving the README, so the CI badge
# needs no owner or repo name and survives any future rename.
BADGE = re.compile(
    r"\[!\[CI\]\(https://github\.com/[^/)]+/[^/)]+/actions/workflows/ci\.yml/badge\.svg\)\]"
    r"\(https://github\.com/[^/)]+/[^/)]+/actions/workflows/ci\.yml\)"
)
BADGE_REL = "[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)"


def is_text(path, name):
    if name in TEXT_NAMES:
        return True
    return os.path.splitext(name)[1] in TEXT_SUFFIXES


def rewrite(text, name):
    if name == "README.md":
        text = BADGE.sub(BADGE_REL, text)
    for pattern, repl in RULES:
        text = pattern.sub(repl, text)
    text = BARE.sub(ORG, text)
    return BARE_LOWER.sub(ORG.lower(), text)


# Only rewrite files git tracks. Ignored scratch (fuzz output, caches, local
# notes) can hold absolute paths that merely look like org references, and
# rewriting those corrupts data without changing anything that ships.
try:
    tracked = set(subprocess.run(
        ["git", "-C", DIR, "ls-files", "-z"],
        capture_output=True, check=True,
    ).stdout.decode("utf-8").split("\0"))
    tracked.discard("")
except (subprocess.CalledProcessError, OSError, UnicodeDecodeError):
    tracked = None  # not a git checkout - fall back to rewriting everything

changed = []
for root, dirs, files in os.walk(DIR):
    dirs[:] = [
        d for d in dirs
        if d not in SKIP_DIRS
        # Nested checkouts are their own repos and get their own pass.
        and not os.path.isdir(os.path.join(root, d, ".git"))
    ]
    for name in files:
        path = os.path.join(root, name)
        if not is_text(path, name):
            continue
        if tracked is not None and os.path.relpath(path, DIR) not in tracked:
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                before = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        after = rewrite(before, name)
        if after == before:
            continue
        changed.append(os.path.relpath(path, DIR))
        if not DRY_RUN:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(after)

if not changed:
    sys.exit(0)

verb = "WOULD UPDATE" if DRY_RUN else "UPDATED"
print("%s %s (%d file(s))" % (verb, REPO, len(changed)))
for rel in sorted(changed):
    print("    %s" % rel)
sys.exit(10)
