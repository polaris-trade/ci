# CI Setup

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/License-MIT%20OR%20Apache--2.0-blue.svg)](#license)

Shared, reusable GitHub Actions workflows for every module. Right now only supports Rust modules. Central home for CI conventions — one PR here rolls out to all callers on next dispatch.

## Layout

```
ci/
  .github/
    workflows/
      rust-ci.yml        # workflow_call: fmt, clippy, cargo nextest, 3-OS × 3-toolchain matrix
      pr-title.yml       # workflow_call: Conventional Commits PR title lint
      release-please.yml # workflow_call: release-please version-bump PR, tag, GitHub Release
      msrv-bump.yml      # workflow_dispatch: fan out MSRV bump PRs to downstream repos
  downstream.example.json  # schema reference. Real list lives in vars.DOWNSTREAM_REPOS.
  README.md
```

## Consuming from another repo

Reusable workflows are called with `uses: OWNER/REPO/.github/workflows/<name>.yml@REF`. Callers stay thin — one job stanza each.

### `.github/workflows/ci.yml` (caller)

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:

jobs:
  rust:
    uses: {org|user}/ci/.github/workflows/rust-ci.yml@main
    # optional:
    # with:
    #   workspace-args: "--all-features"
    #   run-ignored: false
    #   extra-toolchains: '["beta"]'
```

MSRV is read from the caller repo's `rust-toolchain.toml` at run time. **No `msrv:` input.** Bump `rust-toolchain.toml` — that is the only source of truth per module.

### `.github/workflows/pr-title.yml` (caller)

```yaml
name: pr-title
on:
  pull_request:
    types: [opened, edited, reopened, synchronize]

jobs:
  lint:
    uses: {org|user}/ci/.github/workflows/pr-title.yml@main
```

### `.github/workflows/release.yml` (caller)

```yaml
name: release
on:
  push:
    branches: [main]

jobs:
  release:
    uses: {org|user}/ci/.github/workflows/release-please.yml@main
    secrets:
      release-token: ${{ secrets.RELEASE_PLZ_TOKEN }}
```

Each caller also carries a `release-please-config.json` (release-type `rust`, `component` = crate name, `include-component-in-tag`) and a `.release-please-manifest.json` (current version) at its repo root.

## What `rust-ci.yml` runs

For every push and PR:

1. `resolve-msrv` — parses `channel = "..."` from `rust-toolchain.toml`, builds toolchain matrix.
2. `fmt` — `cargo fmt --all --check` on ubuntu-latest.
3. `test` matrix: `{ubuntu, macos, windows} × {msrv, stable, nightly}` = 9 jobs.
   - `cargo clippy --workspace --all-targets -- -D warnings`
   - `cargo nextest run --workspace --no-fail-fast`
   - `cargo test --workspace --doc`
4. Optional `cargo nextest --run-ignored ignored-only` when `run-ignored: true`.

Caching via `Swatinem/rust-cache@v2`, keyed on os+toolchain. `cargo-nextest` installed via `taiki-e/install-action` — prebuilt binary, no source build.

## Bumping MSRV globally (automated)

Single source of truth per module = its own `rust-toolchain.toml`. Central authority for what MSRV _should_ be = the `msrv-bump.yml` workflow_dispatch input.

Run from GitHub UI on the `ci` repo → Actions → `msrv-bump` → Run workflow:

- Input: new MSRV (e.g. `1.98.0`).
- Reads target repos from **`vars.DOWNSTREAM_REPOS`** (private Actions variable — never committed to this public repo).
- For each: checks out, updates `rust-toolchain.toml` `channel`, updates `Cargo.toml` `[workspace.package] rust-version`, opens a PR titled `chore(msrv): bump to <version>`.

### One-time setup on the `ci` repo

1. **`vars.DOWNSTREAM_REPOS`** — Settings → Secrets and variables → Actions → **Variables** tab → New repository variable. Paste JSON matching `downstream.example.json`:
   ```json
   {
     "repos": [{ "repo": "{org|user}/{repo-name}", "base_branch": "main" }]
   }
   ```
   Repository variables are plaintext but not in git and only visible to users with write access to the repo. Perfect for a private list on a public repo. Not a secret — do not use it for tokens.
2. **`secrets.MSRV_BUMP_TOKEN`** — Settings → Secrets and variables → Actions → **Secrets** tab. PAT with `repo` scope, write access to every repo in `DOWNSTREAM_REPOS`. Prefer a fine-grained PAT with `contents: write` + `pull-requests: write` scoped to just those repos.

Merge each generated PR when green.

## Release process

Every module wires `release-please.yml`. Under the hood: `googleapis/release-please-action`.

- Reads Conventional Commits since last tag (already enforced by `pr-title.yml`).
- Opens a release PR bumping `Cargo.toml` version + generating `CHANGELOG.md`.
- On merge: tags `<crate>-vX.Y.Z` and creates a GitHub Release with the changelog section. No `cargo publish` — every crate sets `publish = false` (git-tag distribution).

Single source of truth: `.release-please-manifest.json` version + commit history. No manual `git tag`.

Why not `release-plz`: it runs `cargo package` internally to compute the next version, and `cargo package` cannot resolve an unpublished cross-repo git dependency (`transport_core` is git-tag only, on no registry), so it fails. release-please only edits `Cargo.toml` + `CHANGELOG.md` as text, so unpublished git deps are a non-issue.

### Required secrets per consuming repo

- `RELEASE_PLZ_TOKEN` — PAT with `contents: write` + `pull-requests: write`. Cannot use the default `GITHUB_TOKEN` (its PRs don't trigger downstream workflows).

## Pinning `@ref`

`@main` = latest. For prod modules pin `@vX.Y.Z` tags cut in the `ci` repo, or `@<sha>`. Renovate/Dependabot can bump reusable-workflow refs.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
