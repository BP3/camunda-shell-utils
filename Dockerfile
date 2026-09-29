# SPDX-License-Identifier: MIT
# Copyright (c) 2026 BP3 Global Inc.
#
# The c8sh image: c8sh on Alpine, whose sh and tools are BusyBox's.
#
#   docker build -t c8sh .            the image
#   docker build --target test .      run the test suite inside it first
#
# Run it with your profiles mounted at /config (see the README):
#
#   docker run --rm -it -v ~/.config/camunda:/config c8sh process list

FROM alpine:3.24.2 AS runtime

# curl and jq are all c8sh needs beyond the base system. The user matches
# BP3's other images (bp3user, uid 1001).
RUN apk add --no-cache ca-certificates curl jq && \
    addgroup -g 1001 bp3 && \
    adduser -u 1001 -G bp3 -h /home/bp3user -s /bin/sh -D bp3user

# The commands keep the executable bits they have in git. (COPY --chmod would
# apply its mode to the directories it creates too, e.g. 644 to lib/.)
COPY bin/ /opt/c8sh/bin/
COPY libexec/c8sh/ /opt/c8sh/libexec/c8sh/
COPY lib/camunda.sh /opt/c8sh/lib/camunda.sh
COPY LICENSE /opt/c8sh/LICENSE
RUN chmod -R a+rX,go-w /opt/c8sh

# Profiles are mounted at /config. Tokens are cached in /tmp, which works
# whatever user the container runs as (e.g. --user "$(id -u)" on Linux).
ENV PATH=/opt/c8sh/bin:$PATH \
    CAMUNDA_CONFIG_DIR=/config \
    XDG_CACHE_HOME=/tmp/cache

USER bp3user
WORKDIR /home/bp3user

ENTRYPOINT ["c8sh"]
CMD ["--help"]

LABEL org.opencontainers.image.title="c8sh" \
      org.opencontainers.image.description="Shell tools for the Camunda 8 Orchestration API" \
      org.opencontainers.image.source="https://github.com/BP3/camunda-shell-utils" \
      org.opencontainers.image.vendor="BP3 Global Inc." \
      org.opencontainers.image.licenses="MIT"

# --- tests: the whole suite, run by BusyBox sh with Alpine's own tools -------

FROM runtime AS test

USER root
RUN apk add --no-cache python3
COPY --chown=bp3user:bp3 tests/ /opt/c8sh/tests/
USER bp3user
RUN TEST_SHELLS='busybox sh' /opt/c8sh/tests/run.sh
