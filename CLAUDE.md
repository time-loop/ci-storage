# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

`time-loop/ci-storage` is a **mirror of the upstream `dimikot/ci-storage`**
(remote `dima`; `origin` is `time-loop/ci-storage`). It is a toolkit for running
self-hosted GitHub Actions runner infrastructure with fast work-directory
caching. It ships several things that work together:

- **`ci-storage`** — a Bash CLI (repo root, the `ci-storage` file) that
  stores/loads a work directory to/from a remote rsync-based storage host,
  using `rsync --link-dest` for differential speed. Also a GitHub Action
  (`action.yml`) wrapping it.
- **Three container images** built from `docker/<name>/`:
  - `ci-storage` — the storage host (sshd + the CLI).
  - `ci-runner` — a self-hosted runner that loads a slot from `ci-storage` on
    boot, registers with GitHub, and waits for jobs.
  - `ci-scaler` — scales runners from GitHub webhook signals (Python; the only
    image with its own unit tests under `docker/ci-scaler/guest/scaler/tests/`).

The primary downstream consumer of the images is a **separate repo,
`time-loop/sd`**.

## Layout

- `ci-storage`, `action.yml` — the CLI tool and its Action wrapper.
- `tests/` — tests for the CLI (`tests/all.sh`).
- `docker/<name>/` — one dir per image; `Dockerfile` + layered entrypoint
  scripts (`root/entrypoint.NN-*.sh` run as root, `guest/entrypoint.NN-*.sh` as
  the runner user, in numeric order).
- `docker/compose.yml` — local/integration testing of all three images together.
- `.github/workflows/ci.yml` — the only workflow.
- `PUBLISH.md` — release + GHCR publishing instructions.

## CI / publishing

`.github/workflows/ci.yml` runs on PRs to `main`, pushes to `main`, and `v*`
tags. Jobs:

- `ci-storage-tool-test`, `ci-storage-action-test` — lightweight, always run.
- `ci-scaler-test`, `build-and-boot-containers`, `spawn-job-test` —
  **self-hosted integration tests**. They require `secrets.CI_PAT` (a GitHub PAT
  to register runners) and self-hosted runner infra. **These are currently red
  in this org** because `CI_PAT` / the infra aren't set up yet. Treat that as a
  known, separate workstream — do not assume you broke them.
- `push-images` — matrix over `[ci-storage, ci-scaler, ci-runner]`. Builds all
  three; **pushes only on non-PR events** to `ghcr.io/<owner>/<image>`
  (i.e. `ghcr.io/time-loop/*`). PRs build but do not push (Dockerfile
  validation). Auth uses the built-in `GITHUB_TOKEN` with `packages: write` —
  **no registry PAT needed**. It depends only on the two lightweight tests, so
  the red integration tests never block publishing.

### Gotchas worth knowing

- **GHCR packages publish private by default.** Making them public is a one-time
  manual UI step per package (Org → Packages → settings → change visibility);
  there is **no REST API** for visibility. See `PUBLISH.md`.
- **No Docker Hub.** Upstream published to `dimikot/*` on Docker Hub; this mirror
  does not (no creds, and not wanted). Don't reintroduce Docker Hub steps.
- **`ci-runner/Dockerfile` still `ADD`s the `ci-storage` tool from
  `raw.githubusercontent.com/dimikot/ci-storage/main/...`.** It works (upstream
  is public) but points at upstream, not this mirror — a candidate for
  self-ownership later.
- The READMEs under `docker/*/` reference `ghcr.io/time-loop/*` as the canonical
  pull path. `time-loop/sd` may still reference `ghcr.io/dimikot/*` until
  repointed in a separate PR.

## Conventions

- This repo is under the `time-loop` org: commits and PR titles follow
  `<type>(<scope>): <description> [<TASK-ID>]` (lowercase subject, squad scope,
  required ClickUp task id). Owning team: `@time-loop/Team-Eng-Engineering-Productivity`.
- Shell scripts: keep them shellcheck-clean (`.shellcheckrc` is configured).
- Pin third-party GitHub Actions to a commit SHA (the workflow already does
  this).
</content>
