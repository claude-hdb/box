#!/usr/bin/env bash
# Dependency-free CLI assertions for box. Run: bash test/cli.sh
#
# Runnable by a NON-root user with NO Incus installed — that is the whole point.
# Anything that needs a real incus daemon (every lifecycle command) is proven the
# way rig proves its root-only paths: source the pure function and drive it against
# a fixture, or grep the load-bearing line so a deleted guard cannot ship green.
# Deliberately no `set -e` — the harness asserts on failing commands.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

# check <desc> <want_exit> <want_substr> <cmd...>
# Runs cmd, asserts exit code and (if non-empty) that combined output
# contains want_substr.
check() {
  local desc="$1" want="$2" substr="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $desc — exit $rc, wanted $want"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$substr" ] && ! printf '%s' "$out" | grep -qF -e "$substr"; then
    echo "FAIL: $desc — output missing '$substr'"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  echo "ok: $desc"; PASS=$((PASS + 1))
}

BOX="$ROOT/bin/box"

# ---------------------------------------------------------------------------
# The CLI contract: dispatch, help, usage errors. No incus needed — these all
# resolve before any daemon call. Exit codes are box's own (0 ok / 1 wrong /
# 2 you-asked-wrong), read straight from bin/box and confirmed by running it.
# ---------------------------------------------------------------------------
# box with no args is 'help' (cmd="${1:-help}"), which prints the general usage
# and exits 0 — NOT rig's exit-2 bare-usage. Assert box's actual contract.
check "no args → general help, exit 0"        0 "USAGE"            "$BOX"
check "no args help names the command form"   0 "box <command>"   "$BOX"
check "--help exits 0"                         0 "USAGE"            "$BOX" --help
check "-h exits 0"                             0 "USAGE"            "$BOX" -h
check "help exits 0"                           0 "USAGE"            "$BOX" help
check "help <command> → that command's usage"  0 "usage: box new"  "$BOX" help new
check "--version exits 0"                       0 "box"             "$BOX" --version
# Unknown command is a usage error (2), and it says so — the suggester may add a
# 'did you mean', but the stem is stable.
check "unknown command exits 2"                2 "unknown command" "$BOX" frobnicate
check "unknown command points at help"         2 "box help"        "$BOX" zzzzzz
# Options before the command are the classic mistake; box names the fix.
check "option before command exits 2"          2 "options come after the command" "$BOX" --json list
# A missing required positional is a usage error carrying that command's synopsis.
check "new without --name exits 2"             2 "usage: box new"    "$BOX" new
check "shell without a box exits 2"            2 "usage: box shell"  "$BOX" shell
check "restore without arg2 needs a box first" 2 "usage: box restore" "$BOX" restore
# An unknown flag is refused, not swallowed as a positional (the --labl bug).
check "unknown flag on list exits 2"           2 "unknown option"   "$BOX" list --nope
# A flag that needs a value and gets none.
check "--name with no value exits 2"           2 "--name needs a value" "$BOX" new --name

# ---------------------------------------------------------------------------
# A shim `id` on PATH: lets us drive the pure tier/DEST logic with canned uid +
# group output, exactly the way rig drives assert_runner_repo against fixtures.
# ---------------------------------------------------------------------------
SHIMDIR="$(mktemp -d)"
cat > "$SHIMDIR/id" <<'SHIM'
#!/usr/bin/env bash
# Fake `id`: -u prints $FAKE_UID, -nG prints $FAKE_GROUPS. Just enough for
# box_tier and install.sh's DEST branch, which only ever ask these two.
case "${1:-}" in
  -u)  printf '%s\n' "${FAKE_UID:-1000}" ;;
  -nG) printf '%s\n' "${FAKE_GROUPS:-}" ;;
  *)   exit 0 ;;
esac
SHIM
chmod +x "$SHIMDIR/id"

# ---------------------------------------------------------------------------
# box_tier as a REAL unit test. The function is pure (id + grep + printf), so
# extract its exact text out of bin/box, source it, and drive it with the shim.
# This proves the admin/restricted/none logic WITHOUT a daemon — the daemon
# never enters box_tier's decision.
# ---------------------------------------------------------------------------
TIER_FN="$(mktemp)"
sed -n '/^box_tier() {/,/^}/p' "$BOX" > "$TIER_FN"
check "box_tier: extracted the function from bin/box" 0 "box_tier() {" cat "$TIER_FN"
check "box_tier: the extracted snippet is valid bash" 0 "" bash -n "$TIER_FN"

tier() { # tier <uid> <space-separated groups> — run box_tier under the shim
  FAKE_UID="$1" FAKE_GROUPS="$2" PATH="$SHIMDIR:$PATH" \
    bash -c '. "$1"; box_tier' _ "$TIER_FN"
}
# UID 0 opens the socket regardless of group → admin, groups unread.
check "box_tier: uid 0 is admin"                 0 "admin"      tier 0 ""
check "box_tier: uid 0 admin even with no groups" 0 "admin"     tier 0 "nogroups"
# incus-admin membership → admin (daemon-global).
check "box_tier: incus-admin group is admin"     0 "admin"      tier 1000 "sudo incus-admin users"
# incus (and NOT incus-admin) → restricted (incus-user confines to own project).
check "box_tier: incus group only is restricted" 0 "restricted" tier 1000 "users incus"
# The distinction is exact: substring-matching 'incus' inside 'incus-admin' would
# misfire, so prove a box with ONLY incus-admin does not read as restricted.
check "box_tier: incus-admin is not misread as restricted" 0 "admin" tier 1000 "incus-admin"
# Neither group → none (box cannot talk to the daemon at all).
check "box_tier: neither group is none"          0 "none"       tier 1000 "users docker"

# The two copies of box_tier (bin/box + host/setup-host.sh) MUST NOT drift — the
# tier decision has to be byte-identical wherever it is made. An empty diff is
# the whole assertion (a differing byte prints and fails the exit-0 check).
check "box_tier: bin/box and setup-host.sh copies are identical" 0 "" \
  bash -c 'diff <(sed -n "/^box_tier() {/,/^}/p" "'"$BOX"'") <(sed -n "/^box_tier() {/,/^}/p" "'"$ROOT"'/host/setup-host.sh")'

# ---------------------------------------------------------------------------
# ensure_boxnet_profile: the one per-project resource #72 converges. Grep that
# it exists, loads the shipped YAML from the install root, and — the property
# that matters — is CALLED at the top of cmd_new BEFORE either mint path, so
# neither `incus copy` (the clone) nor `incus launch --profile box-net` (the
# fresh mint) can fail with "no such profile" in a restricted user's project.
# ---------------------------------------------------------------------------
check "ensure_boxnet_profile: the helper exists" 0 "" \
  grep -qE '^ensure_boxnet_profile\(\) \{' "$BOX"
# $root is a LITERAL we grep for in bin/box (the install root, resolved there) —
# single quotes are the point, as in rig's db checks.
# shellcheck disable=SC2016
check "ensure_boxnet_profile: loads the profile YAML from the install root" 0 "" \
  grep -qF 'incus profile edit box-net < "$root/profiles/box-net.yaml"' "$BOX"
# Ordering, the safety property. Match the CALL (indented, bare) not the
# definition, and not the comments that mention it. Defaults fail closed.
prof_call_at="$(grep -nE '^[[:space:]]+ensure_boxnet_profile[[:space:]]*$' "$BOX" | head -n1 | cut -d: -f1)"
copy_at="$(grep -n 'incus copy ' "$BOX" | head -n1 | cut -d: -f1)"
launch_at="$(grep -n 'incus launch ' "$BOX" | head -n1 | cut -d: -f1)"
check "ensure_boxnet_profile: called (bare) inside cmd_new" 0 "" \
  test -n "$prof_call_at"
check "ensure_boxnet_profile: precedes the clone's incus copy" \
  0 "" test "${prof_call_at:-999999}" -lt "${copy_at:-0}"
check "ensure_boxnet_profile: precedes the fresh incus launch" \
  0 "" test "${prof_call_at:-999999}" -lt "${launch_at:-0}"

# ---------------------------------------------------------------------------
# box expose: the restricted-tier guard. expose edits the daemon-global ACL and
# pins a static NIC address — surfaces incus-user confines a restricted user out
# of. Reaching cmd_expose via the CLI needs a real box (the `box` precondition
# resolves the instance first), so grep the die and assert it precedes the first
# incus call in cmd_expose — a guard that fires only AFTER an incus call already
# failed opaquely would be no guard at all.
# ---------------------------------------------------------------------------
check "expose: the restricted-tier die is present" 0 "" \
  grep -qF 'restricted (incus-group) tier cannot modify' "$BOX"
expose_at="$(grep -n '^cmd_expose() {' "$BOX" | head -n1 | cut -d: -f1)"
guard_at="$(grep -n 'restricted (incus-group) tier cannot modify' "$BOX" | head -n1 | cut -d: -f1)"
first_incus_at="$(awk -v s="${expose_at:-1}" 'NR>=s && /^[[:space:]]*incus /{print NR; exit}' "$BOX")"
check "expose: the guard is the first thing cmd_expose does" \
  0 "" test "${expose_at:-0}" -lt "${guard_at:-999999}"
check "expose: the guard precedes cmd_expose's first incus call" \
  0 "" test "${guard_at:-999999}" -lt "${first_incus_at:-0}"

# ---------------------------------------------------------------------------
# install.sh — #71 global/root install. bash -n first, then drive the actual
# DEST/BINDIR branch with the shim id (the functional proof the contract asks
# for), then grep the root-only pieces that a daemon-free run cannot exercise.
# ---------------------------------------------------------------------------
check "install.sh is valid bash" 0 "" bash -n "$ROOT/install.sh"
# Extract EXACTLY the DEST/BINDIR if/else/fi (the first `id -u -eq 0` block) and
# print what it resolved — the same "run the pure block in isolation" trick rig
# uses for its embedded dump script. Fail closed: a mangled extraction is caught
# by the /opt/box grep below before any resolution is trusted.
DBLOCK="$(mktemp)"
awk '/id -u.*-eq 0/{f=1} f{print} f&&/^fi$/{exit}' "$ROOT/install.sh" > "$DBLOCK"
# The $DEST/$BINDIR here are LITERAL text appended into the extracted block — they
# must expand when that block RUNS, not when this printf writes it. Hence single
# quotes; SC2016 is the intent.
# shellcheck disable=SC2016
printf '\nprintf "DEST=%%s BINDIR=%%s\\n" "$DEST" "$BINDIR"\n' >> "$DBLOCK"
check "install.sh: DEST block extracted (guards the awk)" 0 "/opt/box" cat "$DBLOCK"
check "install.sh: the extracted DEST block is valid bash" 0 "" bash -n "$DBLOCK"

dest() { # dest <uid> [extra env assignments...] — resolve DEST/BINDIR
  local uid="$1"; shift
  FAKE_UID="$uid" HOME=/home/tester PATH="$SHIMDIR:$PATH" env "$@" bash "$DBLOCK"
}
# Root: the global path — a system tree other users can read (#71).
check "install.sh: root → DEST=/opt/box"           0 "DEST=/opt/box"          dest 0
check "install.sh: root → BINDIR=/usr/local/bin"   0 "BINDIR=/usr/local/bin"  dest 0
# Non-root: unchanged, the solo path.
check "install.sh: non-root → DEST=\$HOME/.local"  0 "DEST=/home/tester/.local/share/box" dest 1000
check "install.sh: non-root → BINDIR=\$HOME/.local" 0 "BINDIR=/home/tester/.local/bin"    dest 1000
# BOX_HOME / BOX_BIN still win on BOTH branches — the scripting override.
check "install.sh: BOX_HOME overrides the root default" 0 "DEST=/srv/box"     dest 0    BOX_HOME=/srv/box
check "install.sh: BOX_BIN overrides the root default"  0 "BINDIR=/srv/bin"    dest 0    BOX_BIN=/srv/bin
check "install.sh: BOX_HOME overrides the non-root default" 0 "DEST=/srv/box"  dest 1000 BOX_HOME=/srv/box
rm -f "$DBLOCK"
# The root-only world-readable chmod (#71): the tree is EXECUTED by other users,
# so root must open read+traverse. Grep it, and that it is root-guarded so the
# per-user install stays byte-identical to before.
# $DEST is a LITERAL in the grep pattern (install.sh's own variable) — single
# quotes intended.
# shellcheck disable=SC2016
check "install.sh: root makes the tree world-readable (a+rX)" 0 "" \
  grep -qF 'chmod -R a+rX "$DEST"' "$ROOT/install.sh"
check "install.sh: the a+rX is root-guarded" 0 "" \
  bash -c 'grep -B2 "chmod -R a+rX" "'"$ROOT"'/install.sh" | grep -q "id -u.*-eq 0"'
# #66's flow, preserved: confirm-before-download, and no-op if already installed.
check "install.sh: still confirms before downloading (#66)" 0 "" \
  grep -qF 'confirm "Install box from' "$ROOT/install.sh"
check "install.sh: still no-ops on an existing install (#66)" 0 "" \
  grep -qF 'already installed' "$ROOT/install.sh"

# ---------------------------------------------------------------------------
# host/setup-host.sh — #72 host side. bash -n, then grep the load-bearing lines:
# the shared tier fn, the honest restricted exit, incus-user enablement, and the
# #66 pieces that must survive (SUDO resolution, the apt lock timeout, the sg
# re-exec). All of it needs root + a real apt/incus, so grep is the proof.
# ---------------------------------------------------------------------------
SH="$ROOT/host/setup-host.sh"
check "setup-host.sh is valid bash" 0 "" bash -n "$SH"
check "setup-host.sh: carries the shared box_tier function" 0 "" \
  grep -qE '^box_tier\(\) \{' "$SH"
# The $(box_tier) is a LITERAL we grep for in setup-host.sh — single quotes intended.
# shellcheck disable=SC2016
check "setup-host.sh: exits honestly for a restricted caller" 0 "" \
  grep -qF '[ "$(box_tier)" = restricted ]' "$SH"
check "setup-host.sh: the restricted exit names the incus group" 0 "" \
  grep -qF "You are in the 'incus' group (restricted tier)" "$SH"
check "setup-host.sh: enables incus-user.socket (the restricted substrate)" 0 "" \
  grep -qF 'systemctl enable --now incus-user.socket' "$SH"
check "setup-host.sh: flags incus-user as pending rehearsal (#72 Task 0)" 0 "" \
  grep -qF '#72 Task 0' "$SH"
# #66 preserved.
check "setup-host.sh: SUDO resolved once, empty at UID 0 (#66)" 0 "" \
  grep -qF 'SUDO="sudo"' "$SH"
check "setup-host.sh: apt lock-timeout bound kept (#66)" 0 "" \
  grep -qF 'DPkg::Lock::Timeout=300' "$SH"
check "setup-host.sh: the one-run sg re-exec kept (#66)" 0 "" \
  grep -qF 'exec sg incus-admin' "$SH"
# The restricted honest-exit must precede the SUDO block (which exits 1 for a
# non-root caller lacking sudo, and would bury the honest note as dead code).
restr_at="$(grep -n '= restricted \]; then' "$SH" | head -n1 | cut -d: -f1)"
sudo_at="$(grep -n 'host setup needs root' "$SH" | head -n1 | cut -d: -f1)"
check "setup-host.sh: the restricted exit precedes the SUDO-required error" \
  0 "" test "${restr_at:-999999}" -lt "${sudo_at:-0}"

# ---------------------------------------------------------------------------
# Templates — #65 tmux. `box tmux` runs `tmux new-session` INSIDE the box, so a
# template that never installs tmux fails with "tmux: command not found". Every
# template must carry it in its cloud-init package list.
# ---------------------------------------------------------------------------
for t in blank claude codex grok; do
  check "template '$t': installs tmux (#65)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+tmux$' "$ROOT/templates/$t/user-data.yaml"
done

# ---------------------------------------------------------------------------
# drill/doctor.sh — tier-aware (#72). bash -n, then grep the BOX_TIER branch:
# it reads the exported tier, and under restricted it SKIPS the admin-only
# checks (firewall nft, kernel bridge view) with an honest note and points a
# missing box-net profile at `box new`. Reaching the branch needs a live daemon
# (the tier report sits after the daemon-answering check), so grep is the proof.
# ---------------------------------------------------------------------------
DOC="$ROOT/drill/doctor.sh"
check "doctor.sh is valid bash" 0 "" bash -n "$DOC"
# ${BOX_TIER:-admin} is a LITERAL we grep for in doctor.sh — single quotes intended.
# shellcheck disable=SC2016
check "doctor.sh: reads the exported BOX_TIER (admin when unset)" 0 "" \
  grep -qF 'TIER="${BOX_TIER:-admin}"' "$DOC"
check "doctor.sh: reports the restricted tier up top" 0 "" \
  grep -qF 'Access tier — restricted (incus group)' "$DOC"
check "doctor.sh: restricted skips admin-owned checks honestly" 0 "" \
  grep -qF 'not yours to converge' "$DOC"
check "doctor.sh: restricted points a missing profile at 'box new'" 0 "" \
  grep -qF "'box new' converges it on first" "$DOC"
# The firewall/bridge sections must GATE on restricted, not just mention it —
# a bare `sudo nft` under restricted prompts for a password the caller lacks.
check "doctor.sh: the firewall check gates on the restricted tier" 0 "" \
  bash -c 'grep -A1 "Firewall — the box-to-box drop" "'"$DOC"'" | grep -q "TIER. = restricted"'
check "doctor.sh: the kernel-bridge check gates on the restricted tier" 0 "" \
  bash -c 'grep -A1 "KERNEL.s view" "'"$DOC"'" | grep -q "TIER. = restricted"'

# ---------------------------------------------------------------------------
# drill/multiuser.sh — the #72 Task 0 rehearsal. It is opt-in and destructive
# (creates throwaway system users), so CI never RUNS it — but it must parse, and
# it must stay gated behind its explicit flag so it can never fire by accident.
# ---------------------------------------------------------------------------
MU="$ROOT/drill/multiuser.sh"
check "multiuser.sh exists" 0 "" test -f "$MU"
check "multiuser.sh is valid bash" 0 "" bash -n "$MU"
check "multiuser.sh: gated behind an explicit opt-in flag" 0 "" \
  grep -qF 'BOX_MULTIUSER_REHEARSAL' "$MU"
check "multiuser.sh: refuses to run without the opt-in" 2 "BOX_MULTIUSER_REHEARSAL" \
  bash "$MU"
check "multiuser.sh: names itself the answer to #72 Task 0" 0 "" \
  grep -qF '#72 Task 0' "$MU"

echo "---"
echo "$PASS passed, $FAIL failed"
rm -rf "$SHIMDIR" "$TIER_FN"
[ "$FAIL" -eq 0 ]
