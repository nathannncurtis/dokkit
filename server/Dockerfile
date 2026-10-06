# Builds the Dokkit server. From this folder: docker build -t dokkit .
ARG ELIXIR=1.20.4
ARG OTP=29.1.1
ARG DEBIAN=bookworm-20261005-slim

FROM hexpm/elixir:${ELIXIR}-erlang-${OTP}-debian-${DEBIAN}@sha256:c614221557b7dca2cc2a03a476c2adebe0c236b75562f3dcab6e22f12d335fa5 AS build
RUN apt-get update && apt-get install -y build-essential git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config config
RUN mix deps.compile
COPY priv priv
COPY lib lib
COPY assets assets
RUN mix assets.setup && mix compile && mix assets.deploy && mix release

FROM debian:${DEBIAN}@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
RUN apt-get update && apt-get upgrade -y && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/* && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 PHX_SERVER=true
WORKDIR /app
RUN useradd --system dokkit
COPY --from=build --chown=dokkit /app/_build/prod/rel/dokkit ./
USER dokkit
EXPOSE 4000
# Asks the server itself for the sign-in page, as localhost so it is not sent to https.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT:-4000} && printf 'GET /login HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -qE ' [23][0-9][0-9]'"]
# The database is brought up to date, then the server starts. The setup code is in its output.
CMD ["sh", "-c", "bin/dokkit eval Dokkit.Release.migrate && exec bin/dokkit start"]
