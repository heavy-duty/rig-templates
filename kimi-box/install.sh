#!/usr/bin/env bash
# kimi-box — the OFFICIAL installer (code.kimi.com/install.sh): a uv-managed
# Python tool (kimi-cli), landing `kimi` in ~/.local/bin — uv's tool bin —
# with uv bringing its own managed CPython, so no apt python pin here (the
# mechanism's node stays claude/codex-only for the same reason). Run BY THE
# MECHANISM as root; the install itself runs AS the tenant user, never root:
# grok's lesson — a root-owned install under a 0700 home is a CLI that
# exists and cannot run.
#
# As of 2026-09-03 the vendor URL serves a deprecation shim. Its documented
# KIMI_CLI_FORCE_OLD automation escape pins the legacy kimi-cli; migrating to
# Kimi Code is a separate decision this installer does not make.
#
# The vendor shim installs uv into ~/.local/bin, then re-checks PATH in the
# same shell. rig appends this definition's PATH_LINE only after this script
# runs, so the login shell running the vendor installer is the one shell in
# the tenant's life that does not already have ~/.local/bin on PATH.
set -euo pipefail

if [ ! -e "$TENANT_HOME/.local/bin/kimi" ]; then
  # shellcheck disable=SC2016
  runuser -l "$TENANT_USER" -c 'curl -LsSf https://code.kimi.com/install.sh | KIMI_CLI_FORCE_OLD=1 PATH="$HOME/.local/bin:$PATH" bash'
fi
