# rig-templates — the tenant-role registry

The role definitions [rig](https://github.com/heavy-duty/rig) converges onto
box-minted guests (rig#110). rig keeps the **mechanism** — convergence
discipline, the marker/manifest guards, docker, the context-file renderer
with the box#80 boilerplate; this repo keeps the **registry**: the per-role
data that used to live as case arms in rig's tree. The split exists because
the two move at different cadences — adding an agent tenant is a data PR
here, never a mechanism edit there (rig#109 is the evidence: adding kimi,
pure data, meant editing six files in a mechanism repo).

This registry publishes named releases with a changelog and a repo-local smoke
drill record. rig still pins the immutable commit a release tag names
(`RIG_TEMPLATES_PIN` in `commands/lib/templates.sh`, the `BOX_RELEASE`
discipline), bumped by ordinary reviewed rig PR — so the release makes that
commit legible without making the tag the trust boundary. A mint overrides per
run:

    RIG_TEMPLATES_DIR=<dir>    a local folder, no fetch (tests; try-before-push)
    RIG_TEMPLATES_REF=<ref>    any ref here (or in RIG_TEMPLATES_REPO), fetched
                               as an unauthenticated tarball at bootstrap time
    (neither)                  rig's in-tree pin

## Layout — one directory per role, flat, self-namespaced by suffix

The name carries the family (rig#76): `-box` for box tenants and `-server`
for machine roles. `workstation` is the one intentional suffix-less machine
role because it names the machine itself rather than a server purpose.

    claude-box/
    ├── template.env   KEY="value" data, parsed by rig against an allowlist,
    │                  NEVER sourced: USER, CONTEXT_PATH, CLI_NAME, CLI_SRC,
    │                  PATH_LINE, NEEDS_NODE, APT_EXTRAS, SWAP_SIZE, AGENT, HARDEN_SSHD
    ├── install.sh     the CLI install — the one deliberately executable part,
    │                  run by the mechanism AS ROOT with TENANT_USER /
    │                  TENANT_HOME / TENANT_GROUP / ROLE exported; it drops to
    │                  the tenant user (runuser -l) where the vendor's layout
    │                  demands it
    └── creds.md       the per-vendor creds-free paragraph rig's context
                       renderer splices into the agent-context file

`template.env` grammar: blank lines, `#` comments, and `KEY="value"` —
nothing else. The value is everything between the first `="` and the line's
final `"`, so a `PATH_LINE` may carry inner quotes verbatim. It is data:
rig parses it against the allowlist and refuses anything else by key —
it is never sourced, so a definition cannot execute shell through its data
file. `CLI_SRC` may be `~/`-prefixed; rig expands that to the tenant home by
string substitution. Omit `CLI_SRC` when the install lands on the system
PATH already (codex: an npm global's path is the prefix's fact) — rig then
finds the CLI via `command -v`.

Tenant definitions default to `AGENT="yes"` and `HARDEN_SSHD="no"`, so
definitions written before those keys are unchanged. `AGENT="no"` keeps
`USER` required, refuses agent-only keys and `creds.md`, and makes
`install.sh` optional. `HARDEN_SSHD="yes"` invokes rig's shared sshd
hardening independently of whether an agent is installed.

Machine-role directories are traits-only: their `template.env` allowlist is
`ROOT_DOOR`, `HOST`, and `JOIN`. They carry no `creds.md`; an `install.sh` is
optional in the schema; `gig-server` and `crew-server` are the built-in
machine definitions that carry one (below).

### Swap: `SWAP_SIZE`

box lays no swapfile since 0.11.0 (heavy-duty/box#290), so the four agent
roles and `staging-box` declare `SWAP_SIZE="4G"`: rig converges a `/swapfile`
of that size on a VM (heavy-duty/rig#229) and skips a container. An
unconverged box has no swap — that is box's stated cost, not this registry's.

### The agent tenants' shared `APT_EXTRAS` base

Every agent tenant declares `APT_EXTRAS="cron gh jq python3-venv shellcheck"`,
plus whatever its vendor needs — `claude-box` carries
`cron gh jq zsh python3-venv shellcheck`. `cron gh jq` are the hard
prerequisites of crew's box-side installer, which every agent tenant exists to
run: it exits on a missing `gh` or `jq`, and a missing `crontab` is worse,
because the install completes, *reports success*, and hands the operator an
apt command for a box that will never tick.

`python3-venv shellcheck` are the agents' unprivileged toolchain (#38). Box's
seed image carried them only because box#177 took the tenant's sudo away;
box 0.11.0 (box#253) moves them here. The Debian 13 base image ships no pip
and marks the system Python externally managed, so an agent without sudo has
no other way to a venv or a shell linter.

`test/agent-apt-extras.sh` holds that base, and CI runs it on every PR beside
`rig template-lint` — never inside it, because rig owns its own schema and
must not learn one registry's conventions. Dropping a base package from any
tenant reds CI; adding a vendor package to one does not. The tenant set is
**derived** from `AGENT`, not hand-listed, so `staging-box`'s `AGENT="no"`
takes it out and a fifth vendor tenant arrives already bound to the base.

The base is this registry stating what its tenants need, not the only thing
that supplies it: rig's agent-tenant toolbelt installs `gh`, `jq` and `cron`
itself and asserts `cron.service` is enabled and active (rig#162). The
registry declaring its own requirement is what survives that toolbelt
changing. The toolchain half has no other supplier: rig's toolbelt installs
neither `python3-venv` nor `shellcheck`, so this registry's `APT_EXTRAS` is
the only way they reach a box.

The same check holds the boundary the withdrawn `crew-box` rests on: a tenant
gains crew's **packages** and never crew's **engine**. `~/duty` is
version-managed by crew, whose integrity verdict is built on crew being that
tree's sole writer, so no definition here installs it and no `crew-*-box`
role exists. `drill/drill.sh --crew-member` is the end-to-end evidence —
crew's installer run credential-free on a converged tenant, with cron
**armed** rather than merely installed.

### `gig-server` — gig's host (#36)

The first machine role with an `install.sh`. `HOST="yes"` makes rig install
box and run its host setup; `ROOT_DOOR` and `JOIN` match `runner-server`.
rig runs `gig-server/install.sh` as root, last, from the definition directory.

| | |
|---|---|
| **Inputs** | `GIG_TARBALL` (a gig release source tarball) and `GIG_CONFIG` (heavy-duty/infra's `gig.yaml`): operator-supplied readable paths, because gig and infra are private and rig never fetches config. Missing either exits 2 and prints the invocation: `GIG_TARBALL=… GIG_CONFIG=… rig bootstrap gig-server --users <path>`. |
| **Verifies first** | box on PATH at 0.11.0 or later; an existing `gig` account is a system UID (≤ `SYS_UID_MAX`) with a `nologin`/`false` shell and not in `incus-admin`; `gig config check` on the input (run from the tarball itself), and `host.user` is `gig`. The one download, yq (only when it must be placed), is checked against `gig-server/checksums`, never a fetched sidecar. Any refusal happens before anything is installed. |
| **Places** | gig via its own `install.sh --from` (`/opt/gig/<version>`, `/usr/local/bin/gig`); `/etc/gig/gig.yaml` (0644, replaced only when it differs); system user `gig` (no shell, no home, never in `incus-admin`); `box grant --service gig` with `host.pool` and `host.grant.*`; `/var/lib/gig` (0750 gig:gig, gig's own state); `gig-arm.service` (`gig arm --config /etc/gig/gig.yaml` as gig, `Restart=always`, proposal 0012), installed and **not enabled**: once `/etc/gig/app-key.pem` holds the App key and `gig run --apply` has run, enable it with `sudo systemctl enable --now gig-arm.service`; `gig-bake-watch.service` and its hourly `gig-bake-watch.timer` (`gig bake --if-stale` as gig, heavy-duty/gig#33), installed and **not enabled**: after the first manual bake, enable it with `sudo systemctl enable --now gig-bake-watch.timer`; `gig-doctor.service` and its 5-minute `gig-doctor.timer` (`gig doctor` as root; it drops to gig for its project, heavy-duty/gig#7) with root-owned state in `/var/lib/gig-doctor` (0755, the mode gig doctor keeps), installed and **not enabled**: once `/etc/gig/notify.env` holds `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` and optionally `HEARTBEAT_URL`, enable it with `sudo systemctl enable --now gig-doctor.timer`; a journald drop-in capping the journal at 2G; then `gig host apply --root` and, as gig, `gig host apply`. `gig.yaml` is placed last among the writes, after everything else. mikefarah's yq, which gig needs, is placed in `/usr/local/bin` from the same checksums file only when no `yq` is on PATH at all (see below). |
| **Never places** | Secrets, garm or any of its files (proposal 0012 dropped garm, #49), and any enabled unit: `gig-arm.service` and both timers wait for the operator. |
| **Slots the operator fills** | `/etc/gig/app-key.pem` (empty, 0640 root:gig): the GitHub App key, from Bitwarden (heavy-duty/gig#4). `/etc/gig/notify.env` (empty, 0600 root:root): the Telegram slot (heavy-duty/gig#7). `/etc/gig/tailnet-authkey` (empty, 0640 root:gig): the deploy lane's Tailscale auth key, a reusable, ephemeral, pre-approved key tagged `tag:deploy` whose ACL reaches only the deploy API (proposal 0012); gig pipes it to `tailscale up` over stdin. All three are created once and never overwritten. |
| **Re-run** | On a host converged before #49, removes garm's old layout: stops and disables `garm.service` (when systemd is up), then removes exactly `/etc/systemd/system/garm.service`, `/usr/local/bin/garm`, `/usr/local/bin/garm-cli`, `/etc/garm`, `/var/lib/garm` and `/opt/garm`, and nothing else. Idempotent: same inputs, no writes. gig's installer does nothing when the version is current; files are cmp-guarded; box re-converges the grant on every run. A yq pin bump is a PR here that records its sha256. |

The grant runs before `gig-arm.service` exists: a service reads its groups once,
and one that reaches incus-user before the grant makes an unhardened project
(heavy-duty/box#281). `GIG_SKIP_HOST_APPLY=1` skips the two `host apply`
halves for container CI, which has no Incus; CI stubs `box`.
**yq.** gig finds yq only as `yq` on PATH (no override variable, no
libexec), so the role cannot wire in a private copy. It uses a mikefarah yq
v4.54+ already on PATH; refuses, naming the binary, when any other `yq` is
there (Debian's `yq` package is kislyuk's, a different tool) rather than
shadowing it for every user of the host; and otherwise places the pinned one.

`GIG_SERVER_ASSET_DIR` reads release assets from a directory instead of
downloading them, with the same checksums enforced.

**On a host that already carries a rig role** (ci-server): rig keeps one role
marker, `/etc/rig/role`, and `rig bootstrap gig-server` does not refuse a
second role. It rewrites the marker to `role=gig-server`, re-runs the join and
renames the host to `gig-server` unless `--hostname` is given. On such a host,
run the hook on its own with the same inputs, from a checkout of this
registry at the pinned commit:

    GIG_TARBALL=/path/gig.tar.gz GIG_CONFIG=/path/gig.yaml bash gig-server/install.sh

### `crew-server` — a machine that runs crew (#46)

A box host with crew installed from a pinned, checksummed release and set up
as the machine's one service (heavy-duty/crew#822). `HOST="yes"` makes rig
install box and run its host setup; `ROOT_DOOR` and `JOIN` match
`gig-server`. rig runs `crew-server/install.sh` as root, last, from the
definition directory.

**crew sets itself up; the role never duplicates it.** `crew service setup`
makes the `crew` account and group, `/var/lib/crew`, `/etc/crew/service.conf`,
the box grant (`box grant --service crew --share crew`, with caps), the
`/etc/sudoers.d/crew` rule for group `crew`, `crew-floor.service`, the tick,
restart and reset timers, and `/etc/crew/floor.env` with the floor's password,
generated once and kept. It is idempotent, and `crew service check` reads it
all back. The role adds crew itself, the host's values for setup, and the
operators.

| | |
|---|---|
| **Inputs** (environment, all optional) | `CREW_OPERATORS`: comma-separated existing local users to put in group `crew`; an unknown user exits 2. `CREW_PORT` (default 8420). `CREW_BIND` (default: this host's tailnet IPv4 from `tailscale ip -4`, because the floor is reached over the tailnet; with neither, exit 2). `CREW_INSTANCES`, `CREW_MEMORY`, `CREW_CPU`, `CREW_POOL` with `CREW_POOL_SIZE`: the grant's caps, passed to setup as the matching flags; unset means crew's defaults (6 instances, ¾ of RAM, every CPU). `CREW_SERVER_ASSET_DIR`: read the artifact from a directory instead of downloading it. `CREW_SKIP_SERVICE=1`: install crew only (container CI). |
| **Verifies first** | Every input's shape; the operators exist; box on PATH at 0.11.0 or later; the release artifact `crew-<version>.sh` against the sha256 in `crew-server/checksums`, never the release's sidecar. An unrecorded version is refused, so a crew bump is a PR here. Any refusal happens before anything is installed. |
| **Places** | crew via its own installer (`/opt/crew/versions/<version>`, `/usr/local/bin/crew`), skipped when that version is already current; then `crew service setup --port … --bind … [caps]` on every run; the operators in group `crew` (`usermod -aG`; the role removes nobody). Then `crew service check` must read `service: clean`, or the converge fails with its output. |
| **Never places** | A fleet, a member or a credential. A crew server starts with no fleets (heavy-duty/crew#831): fleets are made from the floor (New fleet), members in its roster, credentials through its Credentials or `crew creds`, and the engine's GitHub App, which reads the boards from the host, through Credentials → Engine (heavy-duty/crew#864). The role writes nothing under `/var/lib/crew/fleets`. |
| **The floor** | `http://<CREW_BIND>:<CREW_PORT>/`, printed at the end of the converge. User and password are in `/etc/crew/floor.env` (0640 root:crew), read as root; the role prints where, never the value. An operator in group `crew` runs plain `crew …` with no password; anyone else gets crew's refusal naming the group. A group change takes effect at the user's next login. |
| **Re-run** | Idempotent. crew's installer is skipped when the version is current, setup reports every unit `same`, and an operator already in the group is left alone. |
| **Removal** | `sudo crew service teardown --purge` stops and removes the units, revokes and purges the box grant, and removes the sudoers rule, the account, the group and the data. crew's files stay; remove them with `sudo rm -rf /opt/crew /usr/local/bin/crew`. |

The pin is `CREW_VERSION` in `install.sh`: `0.1.4-rc26`, the candidate of
crew's seven-day run (heavy-duty/crew#753). `0.1.4` final, promoted from it by
stamps only, is a PR that records its sha256 and moves the pin.

**Read on a real host** (heavy-duty/infra's drill host, through rig's box
install with `host=yes`): `crew service check` reads `service: clean`; a
second converge reports every unit `same`; an operator runs `crew status` with
no password and a user outside the group is refused; the floor answers on
`CREW_BIND:CREW_PORT` with no fleets and New fleet; `/var/lib/crew/fleets` is
empty; `crew service teardown --purge` leaves nothing behind. CI cannot read
these: containers have neither Incus nor systemd.

On a host that already carries a rig role, run the hook on its own with the
same inputs, as for `gig-server`:

    CREW_OPERATORS=alice,bob bash crew-server/install.sh

## CI — rig lints every definition on every PR

rig defines what a valid template is (`rig template-lint`, shipped beside
the mint-time parser that enforces the same schema); this repo's CI runs it
on every definition on every PR, so a broken definition is refused before it
can ever reach a mint. The two gates are not redundant: CI protects the
registry, rig's bootstrap-time parse protects a mint served through
`RIG_TEMPLATES_REPO`/`_DIR` that CI never saw.

The `gig-server` job runs `test/gig-server.test.sh --converge` as root in a
throwaway `debian:13` container, against a fixture gig built in the test (gig
is private; the real tarball is operator-supplied) and the real yq release.
The `crew-server` job does the same with `test/crew-server.test.sh
--converge` and the real crew release artifact, under `CREW_SKIP_SERVICE=1`;
the service verbs go through a stub `crew` that records them.

## The security trade — in bold, not a footnote

**A main-tracked rig-templates repo means every merged PR there executes as
root inside every future mint.** This is acceptable — and an improvement —
only because of three facts together: (1) it *narrows* today's surface,
where all of rig is main-tracked-as-root; (2) the repo is small,
single-purpose, and ceremony-governed with a **human merge** as the gate and
the review panel ahead of it; (3) drills pin the SHA they proved. If any of
those three weakens, the default flips to a pinned `RIG_TEMPLATES_REF`.
install.sh diffs in that repo are the highest-trust review surface in the
org — the reviewer doctrine should say so.

*2026-07-24: the flip that paragraph reserves was taken, before the
migration and by the decider* (rig#110): the default **is** pinned — a
merged PR here reaches mints only through a reviewed pin bump in rig, or
when a mint explicitly sets `RIG_TEMPLATES_REF`. The review posture stands
unchanged: **install.sh diffs here remain the highest-trust review surface**,
because the override path and every future pin bump still ship them as root.
