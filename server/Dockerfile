# Builds the Dokkit server. From this folder: docker build -t dokkit .
ARG ELIXIR=1.20.4
ARG OTP=29.0
ARG DEBIAN=bookworm-20260101-slim

FROM hexpm/elixir:${ELIXIR}-erlang-${OTP}-debian-${DEBIAN} AS build
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

FROM debian:${DEBIAN}
RUN apt-get update && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/* && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 PHX_SERVER=true
WORKDIR /app
RUN useradd --system dokkit
COPY --from=build --chown=dokkit /app/_build/prod/rel/dokkit ./
USER dokkit
EXPOSE 4000
# The database is brought up to date, then the server starts. The setup code is in its output.
CMD ["sh", "-c", "bin/dokkit eval Dokkit.Release.migrate && exec bin/dokkit start"]
