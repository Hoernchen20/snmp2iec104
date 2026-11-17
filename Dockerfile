# syntax=docker/dockerfile:1
#
# snmp2iec104 gateway image, built from source in three stages:
#
#   ui       React UI (npm ci, vite build) -> apps/s2i_web/priv/www
#   build    Erlang release (rebar3 as prod tar), ERTS included
#   runtime  debian slim + the release, running as a non-root user
#
#   docker build -t snmp2iec104 .                       # the image
#   docker buildx build --target artifact -o out .      # only the release
#                                                       # tarball, into out/
#
# The release contains ERTS, linked against the build image's glibc and
# libssl: the tarball (snmp2iec104-<vsn>-<debian codename>-<arch>.tar.gz)
# runs on that Debian release or newer, and the runtime stage must use the
# same release as the erlang image (checked below).

ARG OTP_VERSION=28
ARG NODE_VERSION=22
ARG DEBIAN_RELEASE=trixie

# --- ui ----------------------------------------------------------------------
FROM node:${NODE_VERSION}-${DEBIAN_RELEASE}-slim AS ui
WORKDIR /src/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
# vite writes to ../apps/s2i_web/priv/www
RUN npm run build

# --- build -------------------------------------------------------------------
FROM erlang:${OTP_VERSION} AS build
WORKDIR /src
# dependencies first, so source changes do not refetch them
COPY rebar.config rebar.lock ./
RUN rebar3 as prod get-deps && rebar3 as prod compile --deps_only
COPY config/ config/
COPY apps/ apps/
COPY --from=ui /src/apps/s2i_web/priv/www/ apps/s2i_web/priv/www/
# relx copies only ebin/ and priv/ of OTP apps; the MIB library shows the
# source of the built-in MIBs from snmp's mibs/ directory, so add it.
RUN rebar3 as prod release \
 && rel=_build/prod/rel/snmp2iec104 \
 && snmp=$(erl -noshell -eval 'io:put_chars(code:lib_dir(snmp)), halt().') \
 && cp -r "$snmp/mibs" "$rel/lib/$(basename "$snmp")/" \
 && cd "$rel" \
 && vsn=$(basename "$(dirname releases/*/sys.config)") \
 && . /etc/os-release \
 && mkdir -p /out \
 && tar -czf "/out/snmp2iec104-$vsn-$VERSION_CODENAME-$(uname -m).tar.gz" bin erts-* lib releases

# --- artifact (docker build --target artifact -o <dir> .) ---------------------
FROM scratch AS artifact
COPY --from=build /out/ /

# --- runtime -----------------------------------------------------------------
FROM debian:${DEBIAN_RELEASE}-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libssl3t64 libtinfo6 libstdc++6 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /opt/snmp2iec104 --shell /usr/sbin/nologin s2i
ENV LANG=C.UTF-8
WORKDIR /opt/snmp2iec104
COPY --from=build /out/ /tmp/rel/
# the tarball name carries the build stage's Debian codename: fail here if
# it differs from this stage's (ERTS needs the same libc and libssl)
RUN . /etc/os-release \
 && tar -xzf /tmp/rel/snmp2iec104-*-"$VERSION_CODENAME"-*.tar.gz \
 && rm -rf /tmp/rel \
 && mkdir -p data etc \
 && chown -R s2i:s2i data etc
# Container settings: web UI on all interfaces of the container (the port
# is published by docker), state in the volumes below.
COPY docker/sys.config /tmp/sys.config
# Node name fixed to @localhost: the container hostname changes whenever the
# container is recreated, and the Mnesia schema in data/ is bound to the
# node name. Erlang distribution (remote_console, ping) only listens on the
# container's loopback: the release cookie is not a secret.
RUN rel=$(dirname releases/*/sys.config) \
 && cp /tmp/sys.config "$rel/sys.config" \
 && sed -i 's/^-sname .*/-sname snmp2iec104@localhost/' "$rel/vm.args" \
 && echo '-kernel inet_dist_use_interface {127,0,0,1}' >> "$rel/vm.args" \
 && grep -qx -- '-sname snmp2iec104@localhost' "$rel/vm.args" \
 && rm /tmp/sys.config
ENV ERL_EPMD_ADDRESS=127.0.0.1
USER s2i
# data: Mnesia (configuration, users, audit), SNMP state, MIB cache
# etc:  secret.key for the stored SNMP credentials (back it up separately)
VOLUME ["/opt/snmp2iec104/data", "/opt/snmp2iec104/etc"]
# 8080/tcp web UI + REST API, 2404/tcp IEC 104 (default listener port),
# 162/udp SNMP traps and informs
EXPOSE 8080/tcp 2404/tcp 162/udp
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s \
    CMD ["/opt/snmp2iec104/bin/snmp2iec104", "ping"]
CMD ["/opt/snmp2iec104/bin/snmp2iec104", "foreground"]
