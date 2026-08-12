ARG ELIXIR_VERSION=1.16.3
ARG OTP_VERSION=26.2.5
ARG DEBIAN_VERSION=bookworm-20240612-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Stamped into the release so /api/health and the Studio report the real tag.
ARG KONET_VERSION=0.0.0-dev
ENV KONET_VERSION=${KONET_VERSION}

# BEAM's JIT dual-maps code memory, which QEMU can't emulate — single-map it
# so cross-platform image builds (CI building arm64 on amd64) don't crash.
ENV ERL_FLAGS="+JMsingle true"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/prod.exs config/runtime.exs config/

RUN mix deps.compile

COPY assets/package.json assets/package.json
RUN npm install --prefix assets

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix assets.deploy
RUN mix compile
RUN mix release

# ──────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

# curl is required by the docker-compose/Coolify/Dokploy healthcheck
RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/konet ./

USER nobody

ENV MIX_ENV=prod
ENV PHX_SERVER=true

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:4000/api/health || exit 1

CMD ["/app/bin/konet", "start"]
