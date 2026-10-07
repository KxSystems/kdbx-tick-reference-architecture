# syntax=docker/dockerfile:1
#
# Image for the base tick reference architecture. One image runs every process
# (TP / RDB / HDB / FH / RTE / GW); compose.yaml picks the process via `command`.
#
# Build context is the REPO ROOT (see compose.yaml), not this directory:
#   docker build -f tick/docker/Dockerfile -t kdbx-tick-reference:tick .

ARG BASE_IMAGE=portal.dl.kx.com/kdbx-q:latest-debian12

# The official kdbx-q image ships kx.rest but not the kx.log / printf modules
# that utils/logging.q needs, so fetch them from their upstream repos.
FROM scratch AS modules
ARG KX_LOGGING_REF=main
ARG KX_PRINTF_REF=main
ADD --chmod=644 https://raw.githubusercontent.com/KxSystems/logging/${KX_LOGGING_REF}/log.q /kx/log.q
ADD --chmod=644 https://raw.githubusercontent.com/KxSystems/printf/${KX_PRINTF_REF}/printf.q /kx/printf.q

FROM ${BASE_IMAGE}

USER root
COPY --from=modules /kx/ /opt/kx/mod/kx/

# Processes are launched from the repo root: the q code loads `tick/utils/...`
# relative to the working directory.
WORKDIR /opt/app
COPY --chown=kx:kx tick/src      tick/src
COPY --chown=kx:kx tick/utils    tick/utils
COPY --chown=kx:kx samples/schemas      samples/schemas
COPY --chown=kx:kx samples/analytics    samples/analytics
COPY --chown=kx:kx samples/enrichments  samples/enrichments
COPY --chown=kx:kx tick/docker/healthcheck.q /opt/app/healthcheck.q

# Runtime dirs; created here (owned by kx) so named volumes mounted over them
# inherit the right ownership.
RUN mkdir -p app/tplogs app/hdb app/proclogs \
 && chown -R kx:kx app

ENV TZ=UTC
USER kx
