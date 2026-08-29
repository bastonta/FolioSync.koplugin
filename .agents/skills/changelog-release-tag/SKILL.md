---
name: changelog-release-tag
description: >-
  Automates and guides the process of updating CHANGELOG.md and creating versioned Git release tags.
  Use this skill whenever the user asks to prepare a new release, bump version, update changelog,
  or create a new git tag with release notes.
---

# Changelog & Version Release Tagging Skill

This skill provides a standardized, repeatable procedure for analyzing git commits, updating `CHANGELOG.md` according to the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format, creating the release commit, and producing annotated Git tags (`vX.Y.Z`).

---

## Workflow Overview

```
1. Inspect Git History ──► 2. Determine SemVer ──► 3. Update CHANGELOG.md ──► 4. Verify Extraction ──► 5. Commit & Tag
```

---

## Detailed Step-by-Step Procedure

### 1. Inspect Git History & Unreleased Changes

Find the latest existing tag and inspect all commits since that tag:

```bash
# Find latest tag
git describe --tags --abbrev=0

# View commits since the latest tag
git log $(git describe --tags --abbrev=0)..HEAD --oneline

# If no tags exist, view all commits
git log --oneline
```

### 2. Determine Next Semantic Version

Follow [Semantic Versioning 2.0.0](https://semver.org/):

| Change Type | Conventional Commit Prefix | Version Bump | Example |
| :--- | :--- | :--- | :--- |
| **Breaking Change** | `feat!:`, `fix!:`, `BREAKING CHANGE:` | **MAJOR** (`X.0.0`) | `0.2.5` ➔ `1.0.0` |
| **New Features** | `feat:`, `feat(scope):` | **MINOR** (`x.Y.0`) | `0.2.5` ➔ `0.3.0` |
| **Bug Fixes / Chores** | `fix:`, `perf:`, `refactor:`, `style:` | **PATCH** (`x.y.Z`) | `0.2.5` ➔ `0.2.6` |

> [!NOTE]
> For pre-1.0.0 versions (`0.y.z`), breaking changes or large features often bump minor (`0.3.0`), while normal additions/fixes bump patch (`0.2.6`).

---

### 3. Update `CHANGELOG.md`

1. Ensure [CHANGELOG.md](./examples/CHANGELOG-TEMPLATE.md) exists in the repository root.
2. Group changes into the standard Keep a Changelog categories:
   - `### Added` for new features.
   - `### Changed` for changes in existing functionality.
   - `### Deprecated` for soon-to-be removed features.
   - `### Removed` for now removed features.
   - `### Fixed` for any bug fixes.
   - `### Security` in case of vulnerabilities.
3. Move items from `## [Unreleased]` into the new version section with the current date:
   ```markdown
   ## [Unreleased]

   ## [X.Y.Z] - YYYY-MM-DD

   ### Added
   - Description of feature...

   ### Fixed
   - Description of bug fix...
   ```

---

### 4. Verify Release Notes Extraction (if supported)

If the project includes a release notes extraction script (e.g. `scripts/extract-changelog.cjs`):

```bash
node scripts/extract-changelog.cjs vX.Y.Z
```

Verify that:
- The target version is matched correctly.
- The extracted markdown contains all expected bullet points without syntax errors.

---

### 5. Create Release Commit & Git Tag

```bash
# 1. Stage CHANGELOG.md (and any version files like package.json if needed)
git add CHANGELOG.md

# 2. Create release commit
git commit -m "chore(release): vX.Y.Z"

# 3. Create annotated git tag (use -a with -m to avoid hanging on interactive editor)
git tag -a vX.Y.Z -m "chore(release): vX.Y.Z"
```

> [!IMPORTANT]
> Always pass `-a` and `-m "<message>"` when creating git tags to prevent git from opening interactive editor prompts (like Vim) in non-interactive terminals.

---

### 6. Push Release & Trigger CI/CD

Provide the user with the exact commands to push the branch and the new tag:

```bash
git push origin <current-branch>
git push origin vX.Y.Z
```
*(or `git push origin <current-branch> --tags`)*
