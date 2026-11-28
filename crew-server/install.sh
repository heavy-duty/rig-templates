#!/usr/bin/env bash
# crew-server — the machine role that makes a host run crew as its one service
# (#46, heavy-duty/crew#822). rig runs this AS ROOT, last, from this directory;
# it is equally runnable on its own with the same inputs (see README).
#
# crew sets itself up: `crew service setup` makes the account, the group, the
# box grant, the sudoers rule, the config and the systemd units, idempotently,
# and `crew service check` reads them back. This role adds only what crew does
# not: crew itself, from a pinned and checksummed release; the host's values
# for setup; and the operators in group crew. It places no fleet, no members
# and no credentials — a crew server starts with none (heavy-duty/crew#831),
# and fleets are made from the floor.
#
# Two phases. Everything that can refuse — the inputs, the operators, box's
# version, the artifact against ./checksums — runs first, in a temporary
# directory, so a refusal leaves nothing installed. Only then does the second
# phase write, and every step is a no-op on a re-run with the same inputs.
#
# Inputs (environment), all optional:
#   CREW_OPERATORS          comma-separated existing local users for group crew
#   CREW_PORT               the floor's port (default 8420)
#   CREW_BIND               the floor's address (default: this host's tailnet
#                           IPv4, `tailscale ip -4`)
#   CREW_INSTANCES, CREW_MEMORY, CREW_CPU, CREW_POOL, CREW_POOL_SIZE
#                           the box grant's caps, passed to setup as the
#                           matching flags; unset means crew's defaults
#   CREW_SERVER_ASSET_DIR   read the release artifact from this directory
#                           instead of downloading it; ./checksums is enforced
#                           either way
#   CREW_SKIP_SERVICE       1 installs crew only: no setup, no operators, no
#                           check (container CI, which has no Incus or systemd)
#
# Exit codes: 0 converged, 1 refused or failed, 2 missing or invalid inputs.
set -euo pipefail
umask 022

PROG=crew-server
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKSUMS="$HERE/checksums"
CREW_VERSION=0.1.4-rc26
CREW_URL=https://github.com/heavy-duty/crew/releases/download
BOX_FLOOR=0.11.0
SERVICE_GROUP=crew
SAFE_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

log() { printf '%s: %s\n' "$PROG" "$*"; }
die() {
  local code=$1
  shift
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit "$code"
}

SKIP_SERVICE=0
[ "${CREW_SKIP_SERVICE:-}" = 1 ] && SKIP_SERVICE=1

# --- phase 1: verify everything, write nothing outside $WORK ------------------

# Inputs. Each value reaches a command line, so each is checked for its shape.
OPERATORS=()
if [ -n "${CREW_OPERATORS:-}" ]; then
  IFS=',' read -r -a raw_ops <<<"$CREW_OPERATORS"
  for u in "${raw_ops[@]}"; do
    u="${u//[[:space:]]/}"
    [ -n "$u" ] || continue
    [[ $u =~ $SAFE_RE ]] || die 2 "CREW_OPERATORS: '$u' is not a user name"
    getent passwd "$u" >/dev/null || die 2 "CREW_OPERATORS: no local user '$u' on this host; create it first (rig bootstrap --users does) — nothing installed"
    OPERATORS+=("$u")
  done
fi

PORT="${CREW_PORT:-8420}"
if ! [[ $PORT =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  die 2 "CREW_PORT: '$PORT' is not a port (1-65535)"
fi

BIND="${CREW_BIND:-}"
if [ -n "$BIND" ]; then
  [[ $BIND =~ ^[0-9A-Fa-f.:]+$ ]] || die 2 "CREW_BIND: '$BIND' is not an IP address"
elif [ "$SKIP_SERVICE" -eq 0 ]; then
  # The floor is reached over the tailnet: its default address is this host's.
  if command -v tailscale >/dev/null 2>&1; then
    BIND="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi
  [[ $BIND =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die 2 "CREW_BIND is unset and this host has no tailnet IPv4 (tailscale ip -4); join the tailnet first, or name the floor's address: CREW_BIND=<ip>"
fi

CAPS=()
cap() { # cap ENV FLAG REGEX WHAT
  local v="${!1:-}"
  [ -n "$v" ] || return 0
  [[ $v =~ $3 ]] || die 2 "$1: '$v' is not $4"
  CAPS+=("$2" "$v")
}
SIZE_RE='^[0-9]+(KiB|MiB|GiB|TiB|KB|MB|GB|TB)$'
cap CREW_INSTANCES --instances '^[0-9]+$' "a number of instances"
cap CREW_MEMORY --memory "$SIZE_RE" "a size such as 16GiB"
cap CREW_CPU --cpu '^[0-9]+$' "a number of CPUs"
if [ -n "${CREW_POOL:-}" ] || [ -n "${CREW_POOL_SIZE:-}" ]; then
  if [ -z "${CREW_POOL:-}" ] || [ -z "${CREW_POOL_SIZE:-}" ]; then
    die 2 "CREW_POOL and CREW_POOL_SIZE go together (crew service setup --pool NAME --pool-size SIZE)"
  fi
  cap CREW_POOL --pool "$SAFE_RE" "a pool name"
  cap CREW_POOL_SIZE --pool-size "$SIZE_RE" "a size such as 200GiB"
fi

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

# The artifact, against the sha256 this role records — never a fetched sidecar.
ASSET="crew-$CREW_VERSION.sh"
WANT="$(awk -v a="$ASSET" -v v="$CREW_VERSION" '!/^[[:space:]]*#/ && $1 == a && $2 == v { print $3 }' "$CHECKSUMS")"
[[ $WANT =~ ^[0-9a-f]{64}$ ]] ||
  die 1 "$ASSET $CREW_VERSION is not recorded in crew-server/checksums; a crew bump is a role PR that records its sha256 — refusing"
if [ -n "${CREW_SERVER_ASSET_DIR:-}" ]; then
  [ -f "$CREW_SERVER_ASSET_DIR/$ASSET" ] || die 1 "$ASSET: not in CREW_SERVER_ASSET_DIR ($CREW_SERVER_ASSET_DIR)"
  cp -- "$CREW_SERVER_ASSET_DIR/$ASSET" "$WORK/$ASSET"
else
  command -v curl >/dev/null 2>&1 || die 1 "curl is needed to download $ASSET"
  curl -fsSL --proto '=https' -o "$WORK/$ASSET" -- "$CREW_URL/$CREW_VERSION/$ASSET" || die 1 "download of $ASSET failed"
fi
GOT="$(sha256sum -- "$WORK/$ASSET" | cut -d' ' -f1)"
[ "$GOT" = "$WANT" ] || die 1 "$ASSET: checksum mismatch (recorded $WANT, got $GOT) — refusing"

# box: on PATH and new enough for crew's `box grant --service` with caps.
command -v box >/dev/null 2>&1 || die 1 "box is not on PATH; crew's grant is box's (HOST=yes installs it)"
# `box --version` (box has no `version` verb). A box that answers nothing
# usable reads as unknown and is refused below, never a silent exit.
BOX_VERSION="$(box --version 2>/dev/null | awk '{ print $2; exit }' || true)"
[[ $BOX_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] ||
  die 1 "box --version answers no version ('${BOX_VERSION:-nothing}'); crew service setup needs box $BOX_FLOOR or later"
if [ "$(printf '%s\n%s\n' "$BOX_FLOOR" "$BOX_VERSION" | sort -V | head -n1)" != "$BOX_FLOOR" ]; then
  die 1 "box $BOX_VERSION is older than $BOX_FLOOR, which crew service setup needs"
fi
log "verified: $ASSET (sha256 $GOT), box $BOX_VERSION"

# --- phase 2: converge the host ----------------------------------------------

[ "$(id -u)" -eq 0 ] || die 1 "must run as root"

# crew: its own installer, run only when this version is not already the one
# /usr/local/bin/crew resolves to (crew's installer rewrites a current tree).
if [ "$(readlink -f /usr/local/bin/crew 2>/dev/null || true)" = "/opt/crew/versions/$CREW_VERSION/cli/crew" ]; then
  log "crew $CREW_VERSION is already installed and current"
else
  CREW_YES=1 bash "$WORK/$ASSET" || die 1 "crew's installer failed"
  log "installed crew $CREW_VERSION"
fi
INSTALLED="$(crew --version 2>/dev/null | awk '{ print $2; exit }' || true)"
[ "$INSTALLED" = "$CREW_VERSION" ] || die 1 "crew --version answers '${INSTALLED:-nothing}', not $CREW_VERSION"

if [ "$SKIP_SERVICE" -eq 1 ]; then
  log "CREW_SKIP_SERVICE=1 — crew installed only: no service setup, no operators, no check"
  log "converged: crew $CREW_VERSION"
  exit 0
fi

# The service: crew converges it on every run and reports each unit.
crew service setup --port "$PORT" --bind "$BIND" ${CAPS[@]+"${CAPS[@]}"} || die 1 "crew service setup failed (above)"

# Operators: group crew, which setup made. The role adds; it removes nobody.
for u in ${OPERATORS[@]+"${OPERATORS[@]}"}; do
  if id -nG "$u" | tr ' ' '\n' | grep -qx "$SERVICE_GROUP"; then
    continue
  fi
  usermod -aG "$SERVICE_GROUP" "$u" || die 1 "cannot add $u to group $SERVICE_GROUP"
  log "added $u to group $SERVICE_GROUP (takes effect at their next login)"
done

# Read-back: crew's own.
if ! check_out="$(crew service check 2>&1)"; then
  printf '%s\n' "$check_out" >&2
  die 1 "crew service check did not read clean (above)"
fi
printf '%s\n' "$check_out"

# The last line fits the host (heavy-duty/crew#885): "no fleets yet" only on a
# host whose service carries none.
# A host with no fleets has no fleets/ directory: find's non-zero exit must
# not end the converge under pipefail.
FLEETS=""
FLEETS_DIR="${CREW_DATA_DIR:-/var/lib/crew}/fleets"
if [ -d "$FLEETS_DIR" ]; then
  FLEETS="$( { find "$FLEETS_DIR" -mindepth 2 -maxdepth 2 -name fleet.roster 2>/dev/null || true; } | awk -F/ '{ print $(NF-1) }' | sort | paste -sd' ' -)"
fi
if [ -n "$FLEETS" ]; then
  NEXT="fleets: $FLEETS — Members, Repositories and Credentials on the floor"
else
  NEXT="no fleets yet: New fleet on the floor makes the first, and its Credentials → Engine gives the engine its GitHub App"
fi
log "converged: crew $CREW_VERSION; the floor is http://$BIND:$PORT/ — its password is in /etc/crew/floor.env (root:$SERVICE_GROUP, 0640); $NEXT"
