# scanners

A container image with [Trivy](https://github.com/aquasecurity/trivy) and
[Grype](https://github.com/anchore/grype) and their vulnerability databases
already inside it. CI jobs can scan without downloading databases at run time
and without reaching upstream database servers.

The image is rebuilt nightly, but only when something it is built from has
changed: a new Trivy or Grype release, a new database, or a new base image.

## Tags

| Tag | Contents |
|---|---|
| `latest` | Trivy, Grype, Trivy vulnerability DB, Trivy Java DB, Trivy checks bundle, Grype DB |
| `slim` | Same as `latest` without the Trivy Java DB |
| `YYYYMMDD.HHMM` | A specific `latest` build (UTC build time) |
| `YYYYMMDD.HHMM-slim` | A specific `slim` build |

Images are published for `linux/amd64` and `linux/arm64` at
`ghcr.io/jaturu/scanners`. Only the three most recent dated builds of each
variant are kept.

Use `latest` if anything you scan may contain Java archives (JAR, WAR, EAR).
In `slim`, Trivy fails with `The first run cannot skip downloading Java DB`
when it finds one. Grype works the same in both variants.

Approximate size on disk: `latest` 9 GB, `slim` 6.4 GB. Layers are zstd
compressed, so the download is much smaller. Pulling requires Docker 23 or
newer, or containerd 1.5 or newer.

## Usage

As a job container in GitHub Actions:

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    container: ghcr.io/jaturu/scanners:latest
    steps:
      - uses: actions/checkout@v7
      - run: trivy fs --scanners vuln --exit-code 1 --severity HIGH,CRITICAL .
      - run: grype dir:. --fail-on high
```

Scanning an image you just built, from the runner:

```sh
docker save myapp:ci -o myapp.tar
docker run --rm -v "$PWD:/work" ghcr.io/jaturu/scanners:latest \
  trivy image --input /work/myapp.tar
docker run --rm -v "$PWD:/work" ghcr.io/jaturu/scanners:latest \
  grype docker-archive:/work/myapp.tar
```

The image sets these so both tools stay offline:

```
TRIVY_CACHE_DIR=/opt/scanners/trivy
TRIVY_SKIP_DB_UPDATE=true
TRIVY_SKIP_JAVA_DB_UPDATE=true
TRIVY_SKIP_CHECK_UPDATE=true
GRYPE_DB_CACHE_DIR=/opt/scanners/grype
GRYPE_DB_AUTO_UPDATE=false
GRYPE_CHECK_FOR_APP_UPDATE=false
```

The image runs as any UID. Trivy writes its scan cache under
`/opt/scanners/trivy`, which is world-writable.

## Limits

- Grype refuses a database older than 120 hours (its default). If nightly
  builds stop, scans with Grype start failing after five days instead of
  silently using stale data.
- The Trivy checks bundle used by misconfiguration scans (`trivy config`,
  `--scanners misconfig`) is pinned to major version 2, the version current
  Trivy releases expect. A future Trivy release that moves to a new major
  version needs `TRIVY_CHECKS_REPO` in the Dockerfile updated.

## How it is built

`.github/workflows/build.yml` runs nightly and on changes to the build files.

1. `check` resolves every input to an exact version: tool release tags, the
   base image digest, the Trivy DB and checks bundle digests, and the Grype
   DB archive with its checksum. A hash of those inputs is compared with the
   `io.scanners.fingerprint` label on the published image. A variant whose
   hash is unchanged is skipped.
2. `build` runs on a native amd64 runner and a native arm64 runner. Each
   builds with the pinned inputs and pushes by digest.
3. `publish` combines the two architectures under the dated tag, then moves
   `latest` or `slim`.
4. `cleanup` deletes builds older than the newest three per variant.

The database layers are reproducible. When a database has not changed
between builds, its layer digest stays the same, so registries and runners
reuse it.

`workflow_dispatch` takes a `force` input to rebuild both variants.

## Building locally

```sh
docker buildx build --target slim -t scanners:slim .
docker buildx build --target full -t scanners:full .
```

Local builds download the latest databases without pinning. Docker caches
the download step, so add `--no-cache-filter db` to fetch new databases.
