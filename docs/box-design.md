# box design

`box` is a CLI that mints and manages **trust-less, network-isolated VMs
with a coding agent installed** (`claude`, `codex`, `grok`, or `blank` for
none). It is infrastructure, not a project provisioner.

See issue #3 for the full reframe and rationale. This doc captures the durable
design decisions.

## Principle: separate the tool from the agent

- **The tool** mints isolated boxes with the agent installed but **unauthenticated**.
  It knows nothing about projects, secrets, recipes, or memory.
- **The agent** (Claude Code, Codex, Grok — whichever template, inside the box)
  reads an optional `.box/` runbook in a cloned repo and acts on it. The recipe's
  consumer is the reasoning agent, not host machinery.

## Boxes are strictly creds-free

`box new --name <n>` launches a blank box: everything installed, **no**
git credentials and **no** agent credentials. The operator authenticates
interactively *inside* the box:

- **The coding agent** — e.g. `claude` → `/login` (paste-a-code OAuth: copy the
  URL, open it in your own browser, paste the code back); `codex` and `grok`
  have their own login step. Works because the box is outbound-only; the tool
  never handles a token.
- **Git** — the operator adds their own PAT / `gh auth login` inside the box.

The tool stores and injects **no** credentials, ever. This dissolves the
multi-user problem: nothing shared, nothing committed.

## Snapshots are the reuse mechanism

Re-authing every fresh box would be toil, so authenticated state is reused via
snapshots, not a secrets store:

- `box snapshot <n> [label]` — checkpoint after login + clone.
- `box new --name <n2> --from <src>[/<snapshot>]` — clone an existing box
  or snapshot (authed state and all). Isolation is preserved: the clone keeps
  the `box-net` profile + `boxnet` + ACL.
- `box restore <n> <snapshot>` — roll a box back to a checkpoint.

Log in once → snapshot → spin up authed boxes from it.

## The box announces itself to the agent

cloud-init installs a global agent-context file in every coding-agent box
(`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.grok/AGENTS.md`) telling the
agent it is running in a box (trust-less, ephemeral, creds-free) and to treat a
repo's `.box/` folder as its bootstrap runbook. No "tell it" step, no host
execution.

## `.box/` is optional, agent-facing documentation

Not host-executed shell. A repo that wants to be easy to stand up in a sandbox
ships a runbook (prose + optional scripts the agent may run). A repo that does
not, you set up by hand. The tool enforces no contract; there is no `install`.

## What box owns, and what it doesn't

Boxes are ordinary Incus instances, tagged `user.box=1`. That makes every
Incus verb a candidate feature request — `rename`, `info`, `file push`, on
forever — and wrapping them one at a time grows a worse `incus`. The rule:

> **box owns a command when it must enforce an invariant Incus cannot see:**
> the `user.box=1` boundary (never touch an instance we didn't mint), the
> isolation stack (`box-net` profile + `boxnet` + ACL), or the creds-free
> snapshot→clone workflow. Everything else is Incus's job.

The rule cuts both ways, and that's the point:

- `rename` **is** ours — not because it adds logic to `incus rename`, but because
  resolving the name *is* the logic: check the tag, apply `--remote`, and notice
  the box is running (Incus won't rename a running instance) so we can say "stop
  it first" rather than leak an Incus error.
- `incus config set security.nesting=false` is **not** ours. It dismantles the
  trust boundary; wrapping it would imply we bless it.

Two mechanisms keep this honest.

**The command table** (`CMDS` in `bin/box`) is the single source of truth
for what exists, its synopsis, its help line, its preconditions and what runs.
Dispatch and help are both rendered from it, so the help cannot describe a
command that doesn't exist — the failure that produced #8. A thin verb is one
row; a verb that can't be expressed as a row and enforces no invariant of ours
doesn't belong in the tool.

**The escape hatch** — `box incus <box> -- <args...>` — resolves and
tag-checks the box, then hands the rest to Incus verbatim. It means "no" to a
proxy request is not "you can't do that", and it keeps the one rail that matters:
you cannot aim it at an instance box didn't mint. If the command can move
the box off the isolation stack (profile, network, device, `security.*`), it
warns and proceeds — from there the trust boundary is yours to keep.

## Isolation

Dedicated NAT bridge `boxnet` + Incus `box-isolate` ACL dropping all
RFC1918/CGNAT/link-local egress, plus host-firewall rules blocking instance →
host. Entry is `incus exec` over the local socket — no inbound path. The VM is
the trust boundary.

**A box reaches the public internet and nothing else — including no other box.**
That last clause is the one that was assumed and turned out to be false, so it
is spelled out here with the mechanism, and `drill/` tests it on every run.

- **Box → host, LAN, RFC1918, CGNAT, link-local:** the `box-isolate` ACL.
- **Box → box: an nftables *bridge-family* rule** (`host/box-firewall.sh`).
  It cannot be an ACL rule. Two boxes on one bridge share an L2 segment, so
  their frames are *switched* between bridge ports and never traverse the
  netfilter path an L3 ACL lives on — the ACL looked airtight (it drops
  `10.0.0.0/8`, which contains `boxnet`) while box→box was in fact wide open.
  A live probe found box A's SYN arriving at box B. The bridge family's forward
  hook fires exactly on port-to-port frames, which on this bridge means box→box
  and nothing else: gateway traffic and routed egress are delivered locally, not
  forwarded. Dropping every forwarded frame therefore isolates the boxes and
  costs them nothing.
- **Box → box by NAME:** `dns.mode=none`. dnsmasq on the gateway held a record
  for every instance, so a box could enumerate its siblings even where it could
  not reach them. Blocked connections with open reconnaissance is not isolation.
- **IPv6:** off (`ipv6.address=none`), and that is a *contract*, not a default —
  every rule above is IPv4-only, so IPv6 would be an uncovered path.
- **`security.ipv4_filtering`: deliberately NOT used.** It breaks the box's
  networking (in-box Docker cannot pull or run a container). Tested, vetoed.

The rule that keeps this honest: **isolation claims are tested, never reasoned
about.** The box→box hole existed because a plausible code reading said it could
not. See `drill/RUNS.md`.

## Multi-user hosts / access tiers

The dev-server is shared by several operators. box grants them access through
**membership in the `incus` group**, not root — the model
[rig](https://github.com/heavy-duty/rig)'s `box` role ships
([rig#24](https://github.com/heavy-duty/rig/issues/24)). Incus's `incus-user`
daemon confines each `incus`-group member to their **own per-user Incus
project**: they see and manage only their own instances. `incus-admin` is the
full daemon socket — host-root-equivalent, daemon-global, break-glass.

box decides what a process can do **once**, from its *live* credentials, in
`box_tier` (byte-identical in `bin/box` and `host/setup-host.sh`):

| Tier | Who | Can | Cannot |
| --- | --- | --- | --- |
| **admin** | UID 0, or `incus-admin` | everything — build the daemon-global stack (`setup-host`), all projects, `expose` | — |
| **restricted** | `incus` group only | `new` / `list` / `info` / `shell` / `exec` / `tmux` / `snapshot` / `rm` their **own** boxes; `doctor` (tier-aware) | build the daemon-global stack; `expose`; see another user's boxes |
| **none** | neither | nothing — box cannot open the socket | — |

`box_tier` reads argless `id -nG` (the running process's groups, which is what
Incus checks when the socket opens), never `id -nG "$USER"` (the group
*database*, which can list a group a freshly-added shell does not yet hold).

What this means for each surface:

- **`setup-host` is admin-only.** It builds the network, ACL, firewall and the
  `box-net` profile in the `default` project — daemon-global resources. A
  restricted caller is told so honestly and exits 0, rather than dying deep in a
  privileged call: *"you are in the `incus` group … the host's daemon-global
  stack is built by an admin (or by rig at bootstrap)."*
- **The `box-net` profile is converged per-project.** With
  `features.profiles=true` (the default), a project has its **own** profiles and
  only `default` is auto-created — so a restricted user's project does **not**
  inherit the `box-net` profile `setup-host` built in `default`.
  `ensure_boxnet_profile` (called at the top of `cmd_new`, before both mint
  paths) creates it from the shipped YAML the first time it is needed. It is the
  one resource the restricted tier converges itself; the network + ACL it leans
  on stay admin-owned. Networks/ACLs are shared into the project because
  `features.networks=false` keeps them pointing at `default`'s — so a restricted
  user *uses* `boxnet`/`box-isolate` without owning them, and box adds **no**
  `--project` flags anywhere (bare `incus` auto-targets the caller's project).
- **`expose` is admin-only.** It edits the daemon-global `box-isolate` ACL and
  pins a static NIC address — surfaces a restricted user cannot modify. The
  guard fails *early and clearly* at the top of `cmd_expose`, before any `incus`
  call that would otherwise die with an opaque permission error. Ask an admin,
  or run it from an admin account.
- **`doctor` reports the tier and adjusts.** Under restricted it skips the
  admin-owned checks (the nft firewall, the kernel bridge view — both need root
  the caller lacks) with an honest *"not yours to converge"* line, and focuses
  on the one thing the caller owns: whether their project's `box-net` profile
  exists (pointing a miss at `box new`). Admin-tier output is byte-identical to
  before the tier split. `bin/box` publishes the tier by exporting `BOX_TIER`
  before exec-ing `drill/doctor.sh`.
- **Global install is the enabling half** — one world-readable `/opt/box` tree
  every operator runs (see the README's *Global vs per-user install*), so
  granting a new operator access is one `usermod -aG incus`, not a per-user
  reinstall.

**Substrate assumption (assumed-pending-rehearsal).** That the M900s' Incus
ships a working `incus-user` and that a fresh `incus`-group member is
auto-confined to a per-user project is **unverified in this environment** (there
is no Incus here to test against). Every substrate assumption carries that
caveat in the code, and the design is gated on a real-host rehearsal —
`drill/multiuser.sh`, [#72](https://github.com/heavy-duty/box/issues/72) Task 0
— which provisions two throwaway `incus`-group users and asserts confinement
(a), own-box lifecycle (b), cross-user invisibility (c), name-collision
independence (d), the `expose` refusal (e) and the honest `setup-host` note (f).
If confinement does **not** hold, the restricted tier needs a different
per-project mechanism, and that is the fork the code comments name.

## Non-goals

- No unattended/CI bring-up — the flow is interactive.
- No credential storage or injection by the tool.
