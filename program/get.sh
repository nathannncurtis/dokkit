#!/bin/sh
# Puts the dokkit program on this Linux or macOS machine.
#     curl -fsSL https://dokkit.dev/get.sh | sh
# Where to download from: --from <address> (curl -fsSL https://dokkit.dev/get.sh | sh -s -- --from <address>)
# or DOKKIT_RELEASE_BASE, a folder that holds the release's files. With a Dokkit server that holds the
# release, that is https://<server>/api/v1/releases/<version>, and DOKKIT_RELEASE_KEY is a machine key
# the server accepts. Whatever the source, SHA256SUMS must carry a valid Ed25519 signature
# (SHA256SUMS.sig) from the release key below and the download must match it, or nothing is installed.
# The signature is checked with OpenSSL 3, else perl, else python3, whichever this machine has.
# Nothing here reads standard input, so it is safe to pipe; main runs on the last line, so a
# download cut short runs nothing.

die() { echo "get.sh: $*" >&2; exit 1; }

# The release public key, as an Ed25519 SubjectPublicKeyInfo in base64. It is the key in program/version.go.
release_key=MCowBQYDK2VwAyEAxX87EOVIFN9AkYL7vMj40ivpQ36bRyvJGLOMIbgAmRk=

perl_check='
use strict; use Math::BigInt; use Digest::SHA qw(sha512); use MIME::Base64;
my ($spki, $sigb, $file) = @ARGV;
my $A = substr(decode_base64($spki), -32);
my $sig = decode_base64($sigb);
open(my $fh, "<:raw", $file) or exit 2;
my $msg = do { local $/; <$fh> };
exit 1 unless length($sig) == 64;
my $P = Math::BigInt->new(2)->bpow(255)->bsub(19);
my $L = Math::BigInt->new(2)->bpow(252)->badd(Math::BigInt->new("27742317777372353535851937790883648493"));
sub fromle { Math::BigInt->from_hex("0x" . unpack("H*", reverse($_[0]))) }
sub inv { $_[0]->copy->bmodpow($P - 2, $P) }
my $D = (Math::BigInt->new(-121665) * inv(Math::BigInt->new(121666))) % $P;
my $e1 = $P - 1; my $I = Math::BigInt->new(2)->bmodpow(scalar $e1->bdiv(4), $P);
sub rx {
  my ($y, $s) = @_;
  my $y2 = ($y * $y) % $P;
  my $x2 = (($y2 - 1) * inv(($D * $y2 + 1) % $P)) % $P;
  my $e = $P + 3; $e = scalar $e->bdiv(8);
  my $x = $x2->copy->bmodpow($e, $P);
  $x = ($x * $I) % $P if (($x * $x - $x2) % $P) != 0;
  return undef if (($x * $x - $x2) % $P) != 0;
  $x = $P - $x if ($x % 2) != $s;
  return $x;
}
sub dec {
  my $b = shift;
  my $top = ord(substr($b, 31, 1));
  my $y = fromle(substr($b, 0, 31) . chr($top & 127));
  return undef if $y >= $P;
  my $x = rx($y, $top >> 7);
  return undef unless defined $x;
  return [$x, $y, Math::BigInt->bone, ($x * $y) % $P];
}
sub add {
  my ($p, $q) = @_;
  my ($x1, $y1, $z1, $t1) = @$p; my ($x2, $y2, $z2, $t2) = @$q;
  my $a = (($y1 - $x1) * ($y2 - $x2)) % $P; my $b = (($y1 + $x1) * ($y2 + $x2)) % $P;
  my $c = (2 * $t1 * $t2 * $D) % $P; my $d = (2 * $z1 * $z2) % $P;
  my ($e, $f, $g, $h) = ($b - $a, $d - $c, $d + $c, $b + $a);
  return [($e * $f) % $P, ($g * $h) % $P, ($f * $g) % $P, ($e * $h) % $P];
}
sub mul {
  my ($s, $pt) = @_;
  my $q = [Math::BigInt->bzero, Math::BigInt->bone, Math::BigInt->bone, Math::BigInt->bzero];
  for my $bit (split //, substr($s->as_bin, 2)) { $q = add($q, $q); $q = add($q, $pt) if $bit; }
  return $q;
}
my $By = (4 * inv(Math::BigInt->new(5))) % $P;
my $B = [rx($By, 0), $By, Math::BigInt->bone, 0]; $B->[3] = ($B->[0] * $By) % $P;
my $R = dec(substr($sig, 0, 32)); exit 1 unless $R;
my $Ap = dec($A); exit 1 unless $Ap;
my $S = fromle(substr($sig, 32)); exit 1 if $S >= $L;
my $h = fromle(sha512(substr($sig, 0, 32) . $A . $msg)) % $L;
my $l = mul($S, $B); my $r = add($R, mul($h, $Ap));
exit((($l->[0] * $r->[2] - $r->[0] * $l->[2]) % $P) == 0 && (($l->[1] * $r->[2] - $r->[1] * $l->[2]) % $P) == 0 ? 0 : 1);
'

python_check='
import base64, hashlib, sys
spki, sigb, path = sys.argv[1:4]
A = base64.b64decode(spki)[-32:]
sig = base64.b64decode(sigb)
msg = open(path, "rb").read()
if len(sig) != 64: sys.exit(1)
P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
I = pow(2, (P - 1) // 4, P)
def rx(y, s):
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P: x = x * I % P
    if (x * x - x2) % P: return None
    return P - x if x % 2 != s else x
def dec(b):
    y = int.from_bytes(b, "little"); s = y >> 255; y &= (1 << 255) - 1
    if y >= P: return None
    x = rx(y, s)
    return None if x is None else (x, y, 1, x * y % P)
def add(p, q):
    a = (p[1] - p[0]) * (q[1] - q[0]) % P; b = (p[1] + p[0]) * (q[1] + q[0]) % P
    c = 2 * p[3] * q[3] * D % P; d = 2 * p[2] * q[2] % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)
def mul(s, pt):
    q = (0, 1, 1, 0)
    for bit in bin(s)[2:]:
        q = add(q, q)
        if bit == "1": q = add(q, pt)
    return q
By = 4 * pow(5, P - 2, P) % P
Bx = rx(By, 0)
B = (Bx, By, 1, Bx * By % P)
R = dec(sig[:32]); Ap = dec(A)
S = int.from_bytes(sig[32:], "little")
if R is None or Ap is None or S >= L: sys.exit(1)
h = int.from_bytes(hashlib.sha512(sig[:32] + A + msg).digest(), "little") % L
l = mul(S, B); r = add(R, mul(h, Ap))
sys.exit(0 if (l[0] * r[2] - r[0] * l[2]) % P == 0 and (l[1] * r[2] - r[1] * l[2]) % P == 0 else 1)
'

# Succeeds when the signature file holds a good Ed25519 signature of the list, from the release key.
signature_ok() {
  list=$1 sigfile=$2
  sigb64=$(tr -d ' \r\n' < "$sigfile")
  case $(openssl version 2>/dev/null) in
    "OpenSSL 3"*)
      printf '%s\n%s\n%s\n' '-----BEGIN PUBLIC KEY-----' "$release_key" '-----END PUBLIC KEY-----' > "$work/release.pub"
      printf '%s' "$sigb64" | openssl base64 -d -A > "$work/sig.bin" 2>/dev/null
      if openssl pkeyutl -verify -rawin -pubin -inkey "$work/release.pub" -in "$list" -sigfile "$work/sig.bin" >/dev/null 2>&1; then return 0; fi
      ;;
  esac
  if command -v perl >/dev/null 2>&1 && perl -MMath::BigInt -MDigest::SHA -MMIME::Base64 -e1 >/dev/null 2>&1; then
    perl -e "$perl_check" "$release_key" "$sigb64" "$list" </dev/null && return 0
    return 1
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import hashlib, base64' >/dev/null 2>&1; then
    python3 -c "$python_check" "$release_key" "$sigb64" "$list" </dev/null && return 0
    return 1
  fi
  command -v openssl >/dev/null 2>&1 && case $(openssl version 2>/dev/null) in "OpenSSL 3"*) return 1 ;; esac
  die "this machine has no way to check an Ed25519 signature: it needs OpenSSL 3, perl or python3. Nothing was installed."
}

main() {
  set -eu
  base=${DOKKIT_RELEASE_BASE:-https://github.com/nathannncurtis/dokkit/releases/latest/download}
  while [ $# -gt 0 ]; do
    case $1 in
      --from) [ $# -ge 2 ] || die "--from needs an address"; base=$2; shift 2 ;;
      *) die "unknown option $1. The only one is --from <address>." ;;
    esac
  done
  base=${base%/}

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
  fetch() {
    if [ -n "${DOKKIT_RELEASE_KEY:-}" ]; then
      curl -fsSL -H "Authorization: Bearer $DOKKIT_RELEASE_KEY" "$base/$1" -o "$work/$1" </dev/null || die "could not fetch $base/$1. Nothing was installed."
    else
      curl -fsSL "$base/$1" -o "$work/$1" </dev/null || die "could not fetch $base/$1. Nothing was installed."
    fi
  }

  if [ "$(id -u)" = 0 ]; then dest=/usr/local/bin; else dest=$HOME/.local/bin; fi

  work=$(mktemp -d)
  echo "Fetching $base/SHA256SUMS"
  fetch SHA256SUMS
  fetch SHA256SUMS.sig
  signature_ok "$work/SHA256SUMS" "$work/SHA256SUMS.sig" || die "the signature of SHA256SUMS does not check against the release key. Nothing was installed."
  case $(head -n 1 "$work/SHA256SUMS") in "version v"*) ;; *) die "SHA256SUMS does not start with a version line. Nothing was installed." ;; esac
  want=$(awk -v n="$name" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1; exit }' "$work/SHA256SUMS")
  [ -n "$want" ] || die "the signed list has no $name. Nothing was installed."

  echo "Fetching $base/$name"
  fetch "$name"
  got=$(sum "$work/$name")
  [ "$got" = "$want" ] || die "the download's SHA-256 is $got, but the signed list says $want. Nothing was installed."

  mkdir -p "$dest"
  chmod 755 "$work/$name"
  mv "$work/$name" "$dest/dokkit"
  echo "Installed $dest/dokkit"
  case ":$PATH:" in
    *":$dest:"*) ;;
    *) echo "$dest is not on your PATH." ;;
  esac
  installed=no
  if [ "$os" = linux ] && [ -f /etc/systemd/system/dokkit.service ]; then installed=yes; fi
  if [ "$installed" = no ]; then
    echo "Next: $dest/dokkit enrol <address> <token>"
  fi
  if [ "$os" = linux ]; then
    if [ "$installed" = yes ] && [ "$(id -u)" = 0 ]; then
      echo "The service is installed. To run it on this copy: dokkit service update"
    elif [ "$installed" = yes ]; then
      echo "The service is installed. To run it on this copy: sudo $dest/dokkit service update"
    elif [ "$(id -u)" = 0 ]; then
      echo "To keep it running with nobody signed in: dokkit service install"
    else
      echo "To keep it running with nobody signed in, after enrolling: sudo $dest/dokkit service install"
    fi
  fi
}

main "$@"
