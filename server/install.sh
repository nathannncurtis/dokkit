#!/bin/sh
# Installs the Dokkit server on a Debian or Ubuntu machine, or upgrades one that is already here.
# The domain must already point at this machine. Either piped, which pulls a published image:
#     curl -fsSL https://dokkit.dev/install.sh | sudo sh -s -- dokkit.example.com
# or from a checkout of the repository, which builds the image from the checkout:
#     sudo sh server/install.sh dokkit.example.com
# DOKKIT_IMAGE names the image to pull (default ghcr.io/nathannncurtis/dokkit-server:latest) and is kept
# in /opt/dokkit/.env. DOKKIT_COMPOSE_URL is where the piped form fetches compose.yml from.
# Nothing here reads standard input, so it is safe to pipe; main runs on the last line, so a
# download cut short runs nothing.

die() { echo "install.sh: $*" >&2; exit 1; }

main() {
  set -eu
  domain=${1:-}
  dir=/opt/dokkit
  # Piped, $0 is "sh", not a file. A checkout is a script that is a file with a Dockerfile beside it.
  here=
  if [ -f "$0" ] && [ -f "$(dirname "$0")/Dockerfile" ]; then here=$(cd "$(dirname "$0")" && pwd); fi

  [ "$(id -u)" = 0 ] || die "run as root: sudo sh install.sh dokkit.example.com"
  [ -n "$domain" ] || die "give the domain that points at this machine: sudo sh install.sh dokkit.example.com"
  case $domain in
    *[!a-zA-Z0-9.-]* | .* | *. | *..*) die "'$domain' is not a domain name" ;;
  esac
  . /etc/os-release 2>/dev/null || true
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "* | *" ubuntu "*) ;;
    *) die "this needs Debian or Ubuntu. By hand: install Docker with the compose plugin, put server/compose.yml and a .env holding POSTGRES_PASSWORD (letters and digits), SECRET_KEY_BASE and PHX_HOST beside it, then run docker compose --profile caddy up -d --build" ;;
  esac

  command -v curl >/dev/null || { apt-get update && apt-get install -y curl ca-certificates; } </dev/null
  docker compose version >/dev/null 2>&1 || curl -fsSL https://get.docker.com </dev/null | sh

  # Secrets are made once and kept: a later run changes only the domain.
  install -d -m 700 "$dir"
  if [ ! -f "$dir/.env" ]; then
    umask 077
    {
      echo "POSTGRES_PASSWORD=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      echo "SECRET_KEY_BASE=$(head -c 48 /dev/urandom | base64 -w0)"
      echo "PHX_HOST=$domain"
    } > "$dir/.env"
  fi
  sed -i "s/^PHX_HOST=.*/PHX_HOST=$domain/" "$dir/.env"
  if [ -n "${DOKKIT_IMAGE:-}" ]; then
    sed -i '/^DOKKIT_IMAGE=/d' "$dir/.env"
    echo "DOKKIT_IMAGE=$DOKKIT_IMAGE" >> "$dir/.env"
  fi
  image=$(sed -n 's/^DOKKIT_IMAGE=//p' "$dir/.env")

  # A checkout builds, unless an image was named. Piped, the compose file comes from the site.
  if [ -n "$here" ]; then
    compose=$here/compose.yml project=$here
  else
    compose=$dir/compose.yml project=$dir
    curl -fsSL "${DOKKIT_COMPOSE_URL:-https://dokkit.dev/compose.yml}" -o "$compose.new" </dev/null
    mv "$compose.new" "$compose"
    : "${image:=ghcr.io/nathannncurtis/dokkit-server:latest}"
  fi
  [ -z "$image" ] || export DOKKIT_IMAGE=$image

  dc() { docker compose -p dokkit --project-directory "$project" -f "$compose" --env-file "$dir/.env" --profile caddy "$@" </dev/null; }

  if [ -n "$image" ]; then dc pull dokkit; else dc build; fi
  # The image runs its migrations before the server starts.
  dc up -d --remove-orphans

  echo "Waiting for the server."
  i=0
  until [ "$(dc ps --format '{{.Health}}' dokkit)" = healthy ]; do
    i=$((i + 1)); [ $i -le 60 ] || { dc logs --tail 30 dokkit; die "the server did not come up"; }
    sleep 3
  done

  echo "Waiting for the certificate."
  i=0
  until curl -fsS -o /dev/null "https://$domain/login" 2>/dev/null </dev/null; do
    i=$((i + 1)); [ $i -le 30 ] || die "https://$domain did not answer. Does $domain point at this machine, with ports 80 and 443 open? Run again once it does."
    sleep 2
  done

  echo "Dokkit is at https://$domain"
  code=$(dc logs --no-color dokkit | grep -oE 'etup code( is)?: [A-Z0-9]{4}-[A-Z0-9]{4}' | tail -n 1 | awk '{print $NF}')
  if [ -n "$code" ]; then
    echo "The first visit asks for this setup code: $code"
  else
    echo "The first visit asks for a setup code. It is in: docker compose -p dokkit logs dokkit"
  fi
}

main "$@"
