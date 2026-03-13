---
name: release
description: >
  Release a new version of zyouz. Use when the user says "release", "tag", "version bump",
  "cut a release", or wants to publish a new version. Handles git cleanliness check,
  version bump, changelog update, commit, tag, push, and post-release hash updates.
---

# Release Workflow

## Step 1: Ensure clean working tree

Run `git status`. If there are uncommitted changes:
1. Show the changes to the user
2. Ask if they should be committed before proceeding
3. If yes, commit them. If no, abort the release.

## Step 2: Determine version bump

Read the current version from `build.zig.zon`.
Gather commits since the last tag with `git log --oneline $(git describe --tags --abbrev=0)..HEAD`.

Use AskUserQuestion to ask which version bump to apply. Analyze the commits and recommend
the appropriate option:
- **Patch** (bug fixes, minor improvements, documentation) — recommend if all changes are fixes or small additions
- **Minor** (new features, non-breaking changes) — recommend if there are new user-facing features
- **Major** (breaking changes) — recommend if there are breaking API or behavioral changes

Mark the recommended option with "(Recommended)" in the label.

## Step 3: Update version in all locations

These files must be updated to the new version:
- `build.zig.zon` — `.version = "X.Y.Z",`
- `flake.nix` — `version = "X.Y.Z";` (in packages.default)
- `nix/package.nix` — `version = "X.Y.Z";`
- `CHANGELOG.md` — add new section (see below)

Note: `build.zig` derives the version from `build.zig.zon` via `@import`, so it does
not need a manual update.

For `nix/package.nix`, set `hash` to `""` (empty string) temporarily — it will be
updated in step 6 after the tag is published.

## Step 4: Update CHANGELOG.md

Add a new version section at the top (below the header), following the existing
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- ...

### Changed
- ...

### Fixed
- ...
```

Categorize commits into Added/Changed/Fixed/Removed sections. Omit empty sections.
Write entries from the user's perspective, not implementation details.

## Step 5: Commit, tag, and push

```
git add build.zig.zon flake.nix nix/package.nix CHANGELOG.md
git commit -m "Bump version to X.Y.Z"
git tag vX.Y.Z
git push && git push origin vX.Y.Z
```

## Step 6: Wait for Release CI and update nix hash

Watch the CI release workflow with `gh run watch` (the one triggered by the tag push).
Once it succeeds:

1. Compute the new source hash:
   ```
   nix-prefetch-url --unpack "https://github.com/YutaUra/zyouz/archive/refs/tags/vX.Y.Z.tar.gz" 2>&1 | tail -1 | xargs nix hash convert --hash-algo sha256 --to sri
   ```
2. Update `nix/package.nix` with the real hash
3. Commit and push:
   ```
   git add nix/package.nix
   git commit -m "chore: update nix/package.nix hash for vX.Y.Z"
   git push
   ```

## Step 7: Update Homebrew formula

After the GitHub Release is published with all 4 binary assets:

1. Download each asset and compute sha256:
   ```
   for target in x86_64-macos aarch64-macos x86_64-linux aarch64-linux; do
     curl -sL "https://github.com/YutaUra/zyouz/releases/download/vX.Y.Z/zyouz-${target}.tar.gz" | shasum -a 256
   done
   ```
2. Update `Formula/zyouz.rb` in the `~/work/github.com/yutaura/homebrew-tap` repo:
   - Update `version "X.Y.Z"`
   - Update all four `sha256` values
3. Commit and push:
   ```
   cd ~/work/github.com/yutaura/homebrew-tap
   git add Formula/zyouz.rb
   git commit -m "zyouz: update to X.Y.Z"
   git push
   ```
