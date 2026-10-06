#!/bin/sh
# Puts the dokkit program on this Linux or macOS machine.
#     curl -fsSL https://dokkit.dev/get.sh | sh
# DOKKIT_RELEASE_BASE names another place to download from. Nothing here reads standard
# input, so it is safe to pipe; main runs on the last line, so a download cut short runs nothing.

die() { echo "get.sh: $*" >&2; exit 1; }

main() {
  set -eu
  base=${DOKKIT_RELEASE_BASE:-https://github.com/nathannncurtis/dokkit/releases/latest/download}

  case $(uname -s) in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) die "this is for Linux and macOS. On Windows: irm https://dokkit.dev/get.ps1 | iex" ;;
  esac
  case $(uname -m) in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "no build for $(uname -m)" ;;
  esac
  name=dokkit-$os-$arch

  command -v curl >/dev/null || die "curl is needed"
  if command -v sha256sum >/dev/null; then sum() { sha256sum "$1" | cut -d ' ' -f 1; }
  elif command -v shasum >/dev/null; then sum() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
  else die "sha256sum or shasum is needed to check the download"
  fi

  if [ "$(id -u)" = 0 ]; then dest=/usr/local/bin; else dest=$HOME/.local/bin; fi

  work=$(mktemp -d)
  echo "Fetching $base/$name"
  curl -fsSL "$base/$name" -o "$work/$name" </dev/null
  curl -fsSL "$base/$name.sha256" -o "$work/$name.sha256" </dev/null
  want=$(cut -d ' ' -f 1 "$work/$name.sha256" | head -n 1)
  got=$(sum "$work/$name")
  [ -n "$want" ] && [ "$got" = "$want" ] || die "the download's SHA-256 is $got, not $want. Nothing was installed."

  mkdir -p "$dest"
  chmod 755 "$work/$name"
  mv "$work/$name" "$dest/dokkit"
  echo "Installed $dest/dokkit"
  case ":$PATH:" in
    *":$dest:"*) ;;
    *) echo "$dest is not on your PATH." ;;
  esac
  echo "Next: dokkit enrol <address> <token>"
}

main "$@"
