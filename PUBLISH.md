# Publishing a New Version

The CI workflow publishes three multi-arch container images to the GitHub
Container Registry (GHCR) under this repository's owner:

- `ghcr.io/time-loop/ci-storage`
- `ghcr.io/time-loop/ci-scaler`
- `ghcr.io/time-loop/ci-runner`

The `push-images` job authenticates with the built-in `GITHUB_TOKEN`
(`packages: write`), so no registry PAT is required.

## Publish images

Images are published on every push to `main` (tagged `main`) and on version
tags. To cut a new release:

```
git tag vA.B.C # new version
git push --tags
```

A `vA.B.C` tag produces the semver tags plus `latest`.

## One-time: make the packages public

New GHCR packages are created **private** by default. After the first publish,
each package must be switched to public once, via the GitHub UI (there is no
REST API to change package visibility):

> Org → Packages → `<package>` → Package settings → Danger Zone →
> Change visibility → Public

Do this for `ci-storage`, `ci-scaler`, and `ci-runner`. This may require org
admin privileges. Public visibility lets downstream consumers (e.g.
`time-loop/sd`) pull the images anonymously.

## Mirrored third-party images

`.github/workflows/mirror-images.yml` copies each image pinned in
`docker/mirror-images.txt` from Docker Hub to
`ghcr.io/time-loop/mirror/<path>:<tag>` with the same digest, using the same
`GITHUB_TOKEN` login as above. It runs when either file changes on `main`, and
on demand via "Run workflow". To mirror a new image, add its
`<path>:<tag>@<digest>` line and merge; the first run creates the package,
which then needs the same one-time switch to public:

- `mirror/bitnamilegacy/redis-cluster`
- `mirror/bitnamilegacy/redis`
- `mirror/library/alpine`

Add the image here before any consumer points at it: a consumer that pulls a
missing or still-private mirror package fails its pull.

## Release a new GitHub Action version

To release a new GitHub Action version to the GitHub Marketplace (example for v1
overwrite):

```
git pull --rebase
git tag v1 --force
git push --tags --force
```

Then open the v1 release page in the repository and click **Update Release**.
