---
name: ci-tooling
description: CI workflow conventions for Bluefin Server. Use when writing or editing .github/workflows/*.yml, debugging a failing build job, or adding a new CI step.
metadata:
  type: reference
  status: stable
  last_updated: "2026-09-27"
  context7-sources:
    - /websites/github_en_actions
    - /websites/cli_github_manual
---
# CI Tooling

## When to Use

- Writing a new workflow or job.
- Adding a new action dependency.
- Debugging a CI failure in the build or release job.

## When NOT to Use

- Debugging a BST build failure locally (see `bump-fsdk-version.md`).
- Adding build/deployment logic that should live in the `Justfile` instead of CI.

## Org Conventions

### Action pins — always use SHA, never mutable tags

Every `uses:` line must reference a full commit SHA. Never use `@v2` or `@main`.

```yaml
# correct
- uses: taiki-e/install-action@b6b84cf49ebfe0176417bdce007c624f0db37f20 # v2

# wrong — mutable tag, supply-chain risk
- uses: taiki-e/install-action@v2
```

Check `.github/workflows/build.yml` (and sibling repos such as
`projectbluefin/dakota` and `projectbluefin/common`) for the current pinned SHA
before adding an action.

### Installing `just` — taiki-e/install-action, not snap/cargo/apt

Pin the tool version too, not only the action SHA. Without `@<version>`,
`install-action` resolves `just@latest` at run time, so the CI contract
(`just validate`, `just test-unit`, the DDI/kernel export recipes) runs against
a binary chosen by an upstream release rather than by a commit in this repo.

```yaml
- uses: taiki-e/install-action@b6b84cf49ebfe0176417bdce007c624f0db37f20 # v2
  with:
    tool: just@1.58.0
```

The version is repeated at each call site — currently `build.yml`,
`unit-tests.yml`, and `track-junctions.yml`. Bumping `just` means changing all
of them in one commit, so CI never runs two versions at once.

### Workflow permissions

`.github/workflows/build.yml` defaults to a read-only token:

```yaml
permissions:
  contents: read
```

The workflow checks out and executes PR-controlled code (the `Justfile` and
build scripts come from the PR head), so no job that runs on `pull_request`
may hold a write token. In `build.yml`, write tokens are granted to exactly
one job:

- `release` — creates the GitHub Release and pushes the OCI artifact; gated to
  `refs/heads/main`. It holds `contents: write` (release) and
  `packages: write` (ghcr.io push).

Junction ref tracking must never run on `pull_request`. It used to, as a
`track-refs` job gated on `startsWith(github.head_ref, 'renovate/')`, and a
branch name is not an identity. It also pushed its result onto whatever PR
branch happened to be open, so unrelated dependency PRs silently carried
freedesktop-sdk and gnome-build-meta bumps. It now lives in
`track-junctions.yml` on a schedule, opening its own PR on its own branch.

The `build` job (validation, compile, signing) runs with the read-only default
on every event. If a new job needs additional permissions, keep them as narrow
as possible and document why.

### `sudo` scope

Use rootless podman in build jobs wherever possible. Only use `sudo podman` when
the step genuinely requires root (e.g. BST artifact cache access). Do not mix
`sudo podman` and plain `podman` within the same job — pick one based on what the
runner supports and stay consistent.

The `sudo_cmd` Just variable auto-detects at recipe startup:

```just
sudo_cmd := if `podman info >/dev/null 2>&1 && echo 1 || echo 0` == "1" { "" } else { "sudo" }
```

### No PATs; GitHub App tokens for automation that must trigger CI

- Personal Access Tokens (PATs) are banned.
- `repository_dispatch` is not used for build handoff.
- `secrets.GITHUB_TOKEN` is used for release uploads inside `build.yml`.
- Automation that pushes a branch and opens a PR uses the org-wide
  `mergeraptor` GitHub App (`secrets.MERGERAPTOR_APP_ID` /
  `secrets.MERGERAPTOR_PRIVATE_KEY`) via `actions/create-github-app-token`, as
  `projectbluefin/dakota` does. This is not cosmetic: pushes made with
  `secrets.GITHUB_TOKEN` do not dispatch workflow runs, so a PR built that way
  sits at `action_required` with zero jobs and never gets checks.

## Workflow Structure

| Job | Workflow | Trigger | Purpose |
|-----|----------|---------|---------|
| `track-junctions` | `track-junctions.yml` | `schedule` (08:00 UTC), `workflow_dispatch` | Resolves the `freedesktop-sdk.bst` + `gnome-build-meta.bst` junction refs, syncs `project.conf`'s `installer-version`, and opens/updates its own PR on `auto/track-junctions`. `contents: write` + `pull-requests: write`, never on `pull_request`. |
| `build` | `build.yml` | `pull_request`, `push/main`, `workflow_dispatch` | Resolves the element graph, sets `image-version`, and runs the full BuildStream compile of the image set (OS DDI, signed UKIs, netboot ESP, k0s/KubeStellar/OpenZFS sysext assets), which also writes and signs the combined `SHA256SUMS` inside `oci/bluefin-server-image.bst`. On `main` it installs the `BOOT_KEYS_TARBALL` and `SYSUPDATE_SIGNING_KEY` secrets; both are required there. Read-only token. |
| `boot-test` | `build.yml` | `pull_request`, `push/main`, `workflow_dispatch` | Downloads the build job's exported image set and runs the Secure Boot QEMU checks: `scripts/dogfood-diskless.sh --check` (diskless boot) and `scripts/dogfood-install.sh` (install to disk and boot it). Read-only token. |
| `release` | `build.yml` | `push/main`, `workflow_dispatch` | Publishes `dist/diskless/` as-is: an immutable GitHub Release tagged `v<image-version>` plus an ORAS OCI artifact at `ghcr.io/<owner>/bluefin-server:<ver>,latest` (one layer per file, artifact type `application/vnd.projectbluefin.server.release.v1`) (`if: ${{ !failure() && !cancelled() && github.ref == 'refs/heads/main' }}`). `contents: write` + `packages: write`. |
| `docs` | `docs-checks.yml` | `pull_request`, `push/main` | Runs markdown and skill metadata checks via `docs-checks.py`. Read-only token. |
| `unit` | `unit-tests.yml` | `pull_request`, `push/main` | Runs pytest and BATS unit test suites. Read-only token. |

GitHub Actions runs the **complete BuildStream compilation pipeline** using `/mnt`
SSD storage on the runner for podman and BuildStream caches. Release assets are
uploaded to a GitHub Release tagged `v<image-version>` (`YY.MM.<run>` on main).

## Core Process

1. **Renovate tracking:** `renovate.json` is configured with a custom regex
   manager to scan BuildStream junction files (`freedesktop-sdk.bst` and
   `gnome-build-meta.bst`) using the `git-refs` datasource.
 2. **Auto-resolution:** The scheduled `track-junctions` workflow executes
    `just bst source track` to resolve raw tags to full `git-describe` refs,
    syncs `installer-version` to the tracked FSDK point release, and proposes the
    result as its own pull request against `main`.
 3. **Full Compilation:** Builds the OS DDI, signed UKIs, netboot ESP, and the
    k0s, KubeStellar, and OpenZFS systemd-sysext assets on every pull request
    and push to `main`, and signs the combined `SHA256SUMS` inside
    `oci/bluefin-server-image.bst` (gpg sign plus a `gpgv` proof against the
    shipped keyring).
 4. **Boot test:** Downloads the exported image set and runs
    `scripts/dogfood-diskless.sh --check` (diskless Secure Boot boot) and
    `scripts/dogfood-install.sh` (diskless boot, `systemd-sysinstall` to disk,
    boot the installed disk) in QEMU with OVMF.
 5. **Version Derivation:** The release version is set per build with
    `just set-version`: `YY.MM.<run>` on main, `0.<run>` on pull requests so
    a PR build can never sort above a release.
 6. **Automated Publishing:** For pushes to `main` (including Renovate PR
    merges), GitHub Actions publishes `dist/diskless/` as-is: an immutable
    GitHub Release `v<image-version>` and an ORAS OCI artifact
    `ghcr.io/<owner>/bluefin-server:<ver>,latest`. Nodes verify updates
    against the `SHA256SUMS` / `SHA256SUMS.gpg` already in that set.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "It's just a minor version tag, supply-chain risk is low." | One compromised tag push owns every repo using it. Pin to SHA. |
| "I'll check what SHA other repos use later." | Check now — it's one `gh api` call and takes a few seconds. |
| "`tool: just` always installs a working version." | It installs whatever is latest that day. A `just` release can change recipe parsing or `--fmt` output and break CI with no commit in this repo. |

## Red Flags

- Any `uses:` line with a mutable ref (`@v2`, `@main`, `@latest`).
- An `install-action` step whose `tool:` has no `@<version>` — the pin is half
  done, since the action is fixed but the binary it installs is not.
- `sudo podman` in one step and plain `podman` in another step doing the same
  operation.
- A new action not present in any sibling repo — check upstream first.

## Verification

- [ ] Every `uses:` line has a full 40-character SHA and a `# vX` comment.
- [ ] Every `install-action` `tool:` names an explicit version (`just@1.58.0`).
- [ ] `just validate` passes after workflow changes.
- [ ] No new mutable action refs introduced.
- [ ] Release signing happens in `oci/bluefin-server-image.bst`; there is no
      separate CI signing step, and the release job publishes `dist/diskless/`
      as-is (GitHub Release + OCI artifact).
- [ ] The signing secret names (`BOOT_KEYS_TARBALL`, `SYSUPDATE_SIGNING_KEY`)
      match the ones documented in
      `docs/skills/systemd-sysupdate-verification.md`.

## See also

- [systemd-sysupdate-verification.md](systemd-sysupdate-verification.md) — release signing and sysupdate verification.
- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary.
