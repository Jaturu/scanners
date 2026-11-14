# syntax=docker/dockerfile:1
ARG TRIVY_VERSION=latest
ARG GRYPE_VERSION=latest
ARG BASE_IMAGE=debian:trixie-slim

# Tool binaries for the TARGET architecture (end up in the final image)
FROM ghcr.io/aquasecurity/trivy:${TRIVY_VERSION} AS trivy-bin
FROM ghcr.io/anchore/grype:${GRYPE_VERSION}      AS grype-bin

# Tool binaries for the BUILD host (DB download runs natively, never under QEMU)
FROM --platform=$BUILDPLATFORM ghcr.io/aquasecurity/trivy:${TRIVY_VERSION} AS trivy-host
FROM --platform=$BUILDPLATFORM ghcr.io/anchore/grype:${GRYPE_VERSION}      AS grype-host

# ---- DB download stage (arch-independent output) ----
FROM --platform=$BUILDPLATFORM ${BASE_IMAGE} AS db
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=trivy-host /usr/local/bin/trivy /usr/local/bin/trivy
COPY --from=grype-host /grype              /usr/local/bin/grype
# CI pins these to the exact versions it fingerprinted; a change busts the cache.
# Defaults (latest, unverified) are for local builds.
ARG TRIVY_DB_REPO=ghcr.io/aquasecurity/trivy-db:2
ARG TRIVY_JAVA_DB_REPO=ghcr.io/aquasecurity/trivy-java-db:1
ARG GRYPE_DB_URL=
ENV GRYPE_DB_CACHE_DIR=/opt/scanners/grype
RUN trivy image --cache-dir /opt/scanners/trivy --download-db-only --no-progress \
      --db-repository "$TRIVY_DB_REPO" \
 && trivy image --cache-dir /opt/scanners/trivy --download-java-db-only --no-progress \
      --java-db-repository "$TRIVY_JAVA_DB_REPO" \
 && rm -rf /opt/scanners/trivy/fanal \
 # Pin DownloadedAt to UpdatedAt so an unchanged DB gives an identical layer
 && sed -i -E 's/("UpdatedAt":"([^"]*)".*"DownloadedAt":")[^"]*/\1\2/' \
      /opt/scanners/trivy/db/metadata.json /opt/scanners/trivy/java-db/metadata.json \
 && if [ -n "$GRYPE_DB_URL" ]; then grype db import "$GRYPE_DB_URL"; else grype db update; fi \
 && grype db status \
 && rm -f /opt/scanners/grype/6/last_update_check \
 # CI jobs may run as any UID; Trivy writes its scan cache under the cache dir.
 # Done here (not in the final stage) so it doesn't duplicate the DB layers.
 && chmod -R a+rwX /opt/scanners

# ---- slim: tools + Trivy vuln DB + Grype DB (no Java DB) ----
FROM ${BASE_IMAGE} AS slim
ARG TRIVY_VERSION
ARG GRYPE_VERSION
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p -m 0777 /opt/scanners/trivy
COPY --from=trivy-bin /usr/local/bin/trivy /usr/local/bin/trivy
COPY --from=grype-bin /grype              /usr/local/bin/grype
COPY --from=db /opt/scanners/trivy/db /opt/scanners/trivy/db
COPY --from=db /opt/scanners/grype /opt/scanners/grype

ENV TRIVY_CACHE_DIR=/opt/scanners/trivy \
    TRIVY_SKIP_DB_UPDATE=true \
    TRIVY_SKIP_JAVA_DB_UPDATE=true \
    TRIVY_NO_PROGRESS=true \
    GRYPE_DB_CACHE_DIR=/opt/scanners/grype \
    GRYPE_DB_AUTO_UPDATE=false \
    GRYPE_CHECK_FOR_APP_UPDATE=false

LABEL org.opencontainers.image.title="scanners" \
      org.opencontainers.image.description="Trivy + Grype with pre-baked vulnerability databases" \
      io.scanners.trivy-version="${TRIVY_VERSION}" \
      io.scanners.grype-version="${GRYPE_VERSION}"

RUN trivy --version && grype version
WORKDIR /work
CMD ["bash"]

# ---- full: slim + Trivy Java DB ----
FROM slim AS full
COPY --from=db /opt/scanners/trivy/java-db /opt/scanners/trivy/java-db
