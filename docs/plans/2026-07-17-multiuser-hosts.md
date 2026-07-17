# box multi-user hosts — global install + access tiers (#71 + #72)

> **For agentic workers:** this is a failing-tests-first plan. Land the tests
> red, then make them green, then shellcheck-clean exactly as CI runs it, then
> the substrate rehearsal. The **TASK-0 GATE** below is a merge blocker — read it.

**Goal:** make box usable on a host shared by several operators. Two bugs today,
one design:

1. box installs per-user into `$HOME/.local`, so on a shared host every *other*
   user gets `command not found` ([#71](https://github.com/heavy-duty/box/issues/71)).
2. box assumes `incus-admin` full-socket access, so an `incus`-group (non-admin)
   operator cannot use it at all ([#72](https://github.com/heavy-duty/box/issues/72)).

**Why this shape:** the dev-server is shared by 3 operators.
[rig](https://github.com/heavy-duty/rig)'s identity model
([rig#24](https://github.com/heavy-duty/rig/issues/24), shipped) grants operators
the **`box` role = membership in the `incus` group** — *not* `incus-admin`.
Incus's `incus-user` daemon confines each `incus`-group member to their **own
per-user Incus project**: they see and manage only their own instances.
`incus-admin` is host-root-equivalent (the full socket) and is break-glass only.
So box must (a) install once, globally, world-readable, and (b) know which tier
it is running as and behave honestly in each.

**This PR folds and supersedes [PR #66](https://github.com/heavy-duty/box/issues/66)**
(installer runs `setup-host`, one-run convergence, sudo-resolution,
`RemainAfterExit`) — all of #66's work is preserved and built on, not replaced.
It **closes #71, #72, #63, #64, #65.**

## The model

box decides what a process can do with the Incus daemon **once**, from its
*live* credentials, in a function that is byte-identical in `bin/box` and
`host/setup-host.sh` (the tier decision must not drift between where box acts and
where it sets the host up):

```
box_tier():
  UID 0                      -> admin
  member of incus-admin      -> admin        (full socket, daemon-global)
  member of incus (only)     -> restricted   (incus-user: own project only)
  neither                    -> none         (cannot open the socket)
```

Argless `id -nG` — the running **process's** groups, which is what Incus checks
when the socket opens — never `id -nG "$USER"`, which reads the group *database*
and reports a membership a freshly-added shell does not yet hold (the exact bug
#66 fixed in setup-host).

Incus facts that drive the per-tier design (all **assumed-pending-rehearsal**,
see the gate):

- **`features.networks=false`** (project default) → a project shares `default`'s
  networks/ACLs. So `boxnet` + `box-isolate` (admin-built in `default`) are
  usable from a restricted user's project; the admin owns them, restricted only
  uses them. box adds **no** `--project` flags — bare `incus` auto-targets the
  caller's own project.
- **`features.profiles=true`** (project default) → each project has its **own**
  profiles and only `default` is auto-created. So the **`box-net` profile does
  not inherit** into a restricted user's project and must be converged there.
  This is the one resource #72 converges per-project.

## Behavior contracts

### #71 — `install.sh` global/root install

- Root install lands in a **world-readable system tree**, not `$HOME` (`/root`
  is `0700`; a tree there is unreadable to the fleet — the whole bug):
  - root → `DEST=/opt/box`, `BINDIR=/usr/local/bin` (already on every login PATH);
  - non-root → `DEST=$HOME/.local/share/box`, `BINDIR=$HOME/.local/bin` (unchanged);
  - `BOX_HOME` / `BOX_BIN` override both.
- After the move, root makes the tree `chmod -R a+rX` (read for files, +search on
  dirs) — the tree is *executed by other users*. Root-guarded, so the per-user
  install stays byte-identical to before.
- #66's flow preserved: confirm-before-download, **no-op if already installed**,
  `INSTALLED_FROM`/`VERSION` reads (now `$DEST`-aware for free).

### #72 — restricted-tier awareness

- **`host/setup-host.sh`** carries `box_tier`. A non-root caller in `incus` but
  not `incus-admin` is caught **before** the SUDO-resolution block (which would
  otherwise exit 1 and bury the honest note as dead code) and told, honestly,
  that the daemon-global stack is an admin's/rig's job — exit 0, nothing half-built.
  It enables **`incus-user.socket`** (the mechanism the whole restricted tier
  rests on) idempotently, with a `#72 Task 0` pending-rehearsal note. All of
  #66's pieces (SUDO resolution, `DPkg::Lock::Timeout=300`, the one-run
  `sg incus-admin` re-exec, the `SUDO_USER` group grant) stay.
- **`bin/box`** carries `box_tier` and `ensure_boxnet_profile`. The latter is
  called at the **top of `cmd_new`**, before both mint paths (the `incus copy`
  clone and the `incus launch --profile box-net` fresh mint), so neither can fail
  with "no such profile" in a restricted user's project. `cmd_expose` gets a
  tier guard that **fails early and clearly** under restricted (it edits the
  daemon-global ACL + pins a static NIC — surfaces restricted cannot modify).
  `cmd_doctor` exports `BOX_TIER` before exec-ing the doctor.
- **`drill/doctor.sh`** reads `BOX_TIER` (unset ⇒ admin, so a hand-run is
  byte-identical to before). Under restricted it reports the tier and **skips**
  the admin-only checks (nft firewall, kernel bridge view — both need root the
  caller lacks) with an honest "not yours to converge" line, and points a missing
  `box-net` profile at `box new`.

### #65 — tmux in templates

`box tmux` runs `tmux new-session` *inside* the box; a template that never
installs tmux fails with `tmux: command not found`. Every template
(`blank`/`claude`/`codex`/`grok`) installs `tmux` in its cloud-init packages.

## Global constraints

- `#!/usr/bin/env bash`; the existing `log`/`warn`/`die` (install) and
  `ok`/`no`/`inf` (doctor/drill) voices; every non-obvious line justified by the
  *empirical why*, the repo's house style.
- **shellcheck-clean exactly as CI runs it** (`shopt -s globstar; shellcheck -x
  bin/* **/*.sh`), and `bash test/cli.sh` green **as a non-root user with no
  Incus installed**. That constraint is what forces the daemon-free test design.
- Keep the diff minimal — the tier logic is copied *verbatim* across files (a
  test diffs the two copies so they cannot drift); no broad refactor of `bin/box`.
- `VERSION` stays `0.5.0` — "Unreleased" accumulates; the maintainers cut releases.

## Failing-tests-first task list

- [x] **CI** — `.github/workflows/ci.yml`, a single `check` job mirroring rig's:
  globstar `shellcheck -x` + `bash test/cli.sh`. The drill and the multi-user
  rehearsal are **not** in CI (they need a real host/Incus and, for the
  rehearsal, root + real users).
- [x] **Tests first** — `test/cli.sh`, dependency-free and non-root:
  - the CLI contract (no-args/`--help`/`help`/unknown-command/usage errors) with
    exit codes + substrings read from `bin/box` and confirmed by running it;
  - `box_tier` as a **real unit test** — extract the function text with `sed`,
    source it, drive it with a shim `id` on `PATH` to assert
    admin/admin/restricted/none; plus a `diff` proving the `bin/box` and
    `setup-host.sh` copies are identical;
  - `install.sh` DEST/BINDIR resolution driven functionally with the shim `id`
    (root→`/opt/box`, non-root→`$HOME/.local`, `BOX_HOME`/`BOX_BIN` override),
    plus greps for the `a+rX` root-guard and #66's preserved flow;
  - grep-guards for `ensure_boxnet_profile` (exists, loads `$root` YAML, called
    before both mint paths — line-number ordering), the `expose` restricted guard
    (present, precedes the first `incus` call), setup-host's tier/incus-user/#66
    pieces, `tmux` in every template, and doctor's `BOX_TIER` branch;
  - every extracted snippet syntax-checked with `bash -n`, like rig's dump script.
- [x] **Green** — the three pre-existing shellcheck findings in `bin/box` resolved
  (real fixes where they don't change behavior; a targeted `disable` with a reason
  for the genuinely-unused `T_DESC`), the repo lints clean, `bash test/cli.sh`
  all green.
- [x] **doctor tier-awareness**, **docs** (README global-vs-per-user +
  access-tiers pointer; `docs/box-design.md` access-tiers section), this plan,
  the **rehearsal** (`drill/multiuser.sh`), and the consolidated CHANGELOG.
- [ ] **TASK-0 GATE** — the substrate rehearsal on a real host. **See below.**

## 🚨 SUBSTRATE TASK-0 GATE — DO NOT MERGE UNTIL THIS PASSES 🚨

**The restricted tier rests on an UNVERIFIED assumption.** There is no Incus in
the development environment, so whether `incus-user` on the M900s' Incus version
**auto-creates a confined per-user project** for a fresh `incus`-group member is
**unknown**. Every substrate assumption is commented `assumed-pending-rehearsal`
in the code for exactly this reason.

**DO NOT MERGE this PR until an `incus-user` rehearsal on the M900s confirms
per-user project confinement.** Run, on a throwaway host with Incus set up:

```sh
sudo BOX_MULTIUSER_REHEARSAL=1 bash drill/multiuser.sh
```

It provisions two throwaway `incus`-group users and asserts:

| | Criterion |
| --- | --- |
| **a** | an `incus`-group user is auto-confined to their **own** project |
| **b** | they can `box new` / `box list` / `box exec` their own box |
| **c** | they **cannot** see another user's boxes |
| **d** | the same box name in two projects **does not collide** |
| **e** | `box expose` **refuses** for them (daemon-global) |
| **f** | `box setup-host` gives them the **honest restricted note** |

**A FAIL on (a) or (c) is a design veto:** `incus-user` does not confine as
assumed, and the restricted tier needs a different per-project mechanism
(explicit `incus project create` + a per-user token/remote, say) — the fork the
code comments name. Record the outcome in `drill/RUNS.md` either way. Only once
(a) and (c) pass is the restricted tier real, and only then may this merge.

## Test plan

- **Harness (`bash test/cli.sh`, non-root, Incus-free):** the full CLI contract;
  `box_tier` proven pure against a shim `id` (all four tiers) and its two copies
  diffed identical; `install.sh` DEST/BINDIR resolved functionally on both
  branches with overrides; every daemon-gated invariant grepped (with
  line-number ordering where order is the safety property).
- **CI:** `ci.yml` = globstar `shellcheck -x` + the harness. Green on the whole
  repo, `test/cli.sh` included.
- **Rehearsal (manual, out of harness — the TASK-0 GATE):** `drill/multiuser.sh`
  on a real multi-user host, the six criteria above. The main `drill/drill.sh`
  continues to prove the admin tier end-to-end.

---

## 🔴 REHEARSAL RESULTS — Task 0 run, 2026-07-17 (design veto)

Ran on a fresh **Debian 13 / Incus 6.0.4** host with `/dev/kvm` + nested virt.
`host/setup-host.sh` and the #71 global install were exercised for real; the
restricted tier was probed with a throwaway `incus`-group user (`boxuser1`).

### What PASSED (mergeable as-is)
- **#71 global install + `setup-host`**: built the whole stack end-to-end —
  btrfs pool, `boxnet`, `box-isolate` ACL, `box-net` profile, the nft
  `bridge box` box-to-box drop, the firewall unit. `incus-user.socket` is
  shipped, `enabled`, and `active` after setup-host. The `incus`/`incus-admin`
  groups exist.
- **`incus-user` confinement DOES work**: `boxuser1` (in `incus`, NOT
  `incus-admin`) was auto-confined to a restricted project `user-1001`
  ("User restricted project for boxuser1"), seeing only its own instances. The
  core confinement assumption behind the tier is TRUE.

### What FAILED — the design veto (criteria a/b)
`incus-user` on 6.0.4 does **not** share the daemon-global `boxnet` with a
restricted user. It gives each user a **private auto-created bridge
`incusbr-<uid>`** and pins `restricted.networks.access: incusbr-<uid>`:

- `boxuser1` → `incus network show boxnet` → **`Error: Network not found`**.
- `incus launch --profile box-net` (and `ensure_boxnet_profile`) → **fails**:
  the profile references `boxnet`, a network the restricted project may not use.

So box's **entire isolation stack lives on `boxnet`, which restricted users
never touch** — they would instead land on a stock, un-hardened `incusbr-<uid>`
(no ACL, no `dns.mode=none`, no resolver pin, no port-isolation, no nft drop).
`box new` simply does not work for them as written. **This vetoes the current
#72 design**, exactly as this doc's TASK-0 GATE anticipated.

### The fix is real but is a redesign (needs its own PR)
An admin *can* bridge the two worlds, but not the way the code assumes:
- `incus project set user-<uid> restricted.networks.access boxnet,incusbr-<uid>`
  — must list **both** (boxnet alone conflicts with the auto default profile's
  `eth0`, still pinned to `incusbr-<uid>`). Confirmed to resolve the conflict.
- then install the `box-net` profile **into that project** (admin, per user).

Both are **per-project admin actions**, and the restricted project does not
exist until the user first touches `incus` — so `setup-host` cannot pre-create
them. The restricted tier therefore needs an **admin convergence hook** (a
`box grant <user>` / an incus-user project-template config / rig `users apply`
doing it), plus a decision on whether to reuse the auto `incusbr-<uid>`
(hardening it per-user) or force everyone onto the shared `boxnet`.

### Consequence for this PR
- **Split**: #71 (global install), #65 (tmux), CI + tests, and the folded #66
  are verified and should merge as-is.
- **#72 is NOT ready** — the restricted-tier code (tier-aware `setup-host`/
  `doctor`/`expose`, `ensure_boxnet_profile`) stays behind this gate and moves to
  a redesign issue built on these measured facts. Do not merge #72 as written.
