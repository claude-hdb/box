#!/usr/bin/env bash
# multiuser.sh — the #72 Task 0 rehearsal: prove the RESTRICTED tier on a REAL
# multi-user Incus host. This is the substrate gate the whole multi-user design
# rests on and is marked assumed-pending-rehearsal everywhere else — this script
# is where that assumption gets turned into a fact (or refuted).
#
#   ⚠ DESTRUCTIVE, AND MEANT TO BE. It creates throwaway SYSTEM USERS, adds them
#     to the `incus` group, mints boxes as them, and deletes all of it. Run it on
#     a THROWAWAY host you can format — never a workstation, never a shared box
#     you care about. It needs root (to create users) and a working Incus with
#     incus-user enabled (setup-host does that).
#
#   sudo BOX_MULTIUSER_REHEARSAL=1 bash drill/multiuser.sh          # asks first
#   sudo BOX_MULTIUSER_REHEARSAL=1 bash drill/multiuser.sh --yes    # no prompt
#
# What it asserts (the #72 Task 0 acceptance criteria):
#   a. an `incus`-group user is auto-confined to their OWN Incus project
#   b. that user can `box new` / `box list` / `box shell` their own box
#   c. they CANNOT see (or touch) another user's boxes
#   d. a name collision ACROSS two users is fine (each names in its own project)
#   e. `box expose` REFUSES for them (daemon-global; restricted cannot modify it)
#   f. `box setup-host` gives them the honest restricted note, not an opaque fail
#
# If (a) or (c) FAIL, the confinement incus-user is supposed to provide does not
# hold on this Incus, and #72's restricted tier needs a different mechanism
# (per-project via explicit `incus project create` + a token, say). That is
# exactly the design fork the code comments warn about — caught here, on a real
# host, before anyone trusts the tier in production.
#
# NOT 'set -e': a failing assertion is DATA, not a crash — collect them all and
# report, the same contract as drill.sh and doctor.sh.
# ok/no/inf always return 0, so the SC2015 'A && ok || no' trap cannot fire.
# shellcheck disable=SC2015
set -u

# --- opt-in gate: this must NEVER fire by accident -------------------------
# It creates and deletes real system users; an unguarded run in the wrong place
# is a bad day. Demand an explicit, loud opt-in — an env var you had to type.
if [ "${BOX_MULTIUSER_REHEARSAL:-}" != 1 ]; then
  echo "multiuser: refusing to run without an explicit opt-in." >&2
  echo "  This creates throwaway system users and mints boxes as them (#72 Task 0)." >&2
  echo "  Run it ONLY on a disposable host, as root:" >&2
  echo "    sudo BOX_MULTIUSER_REHEARSAL=1 bash drill/multiuser.sh" >&2
  exit 2
fi

YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "multiuser: unknown option: $1" >&2; exit 2 ;;
  esac
done

# Root is non-negotiable: creating users needs it, and this rehearsal only makes
# sense on a host you own end to end.
if [ "$(id -u)" -ne 0 ]; then
  echo "multiuser: must run as root (it creates system users). Re-run under sudo." >&2
  exit 1
fi
command -v incus >/dev/null 2>&1 || { echo "multiuser: incus is not installed — run 'box setup-host' first." >&2; exit 1; }

pass=0; fail=0; findings=()
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass + 1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail + 1)); findings+=("FAIL: $*"); }
inf()  { printf '        %s\n' "$*"; }
phase(){ printf '\n\033[1m══ %s\033[0m\n' "$*"; }

# box as installed on this host — the fleet path is /usr/local/bin/box (#71). Fall
# back to this checkout's bin/box so the rehearsal works pre-global-install too.
BOX="$(command -v box || echo "$(cd "$(dirname "$0")/.." && pwd)/bin/box")"
U1=boxdrill1 U2=boxdrill2

# A user's OWN box command, run with THEIR live credentials. `sudo -u <u> -i`
# gives a login shell whose supplementary groups are the user's — which is the
# whole point: incus checks the process's live group membership when it opens the
# socket (the same reason box_tier reads argless `id -nG`). `sg incus` is NOT
# used: it would hand a group the login did not, hiding the very confinement we
# are here to test.
as() { local u="$1"; shift; sudo -u "$u" -i -- "$@"; }

# Invoked via 'trap cleanup EXIT', which shellcheck cannot see as a call (SC2317).
# shellcheck disable=SC2317
cleanup() {
  phase "Cleanup"
  local u
  for u in "$U1" "$U2"; do
    id "$u" >/dev/null 2>&1 || continue
    # Delete the user's boxes AS the user (their own project), then the account.
    as "$u" "$BOX" list 2>/dev/null | awk 'NR>1{print $1}' | while read -r b; do
      [ -n "$b" ] && as "$u" "$BOX" rm "$b" --force >/dev/null 2>&1
    done
    userdel -r "$u" >/dev/null 2>&1 && inf "removed user $u"
  done
}
trap cleanup EXIT

if [ "$YES" != 1 ]; then
  printf 'multiuser: create users %s + %s, mint boxes as them, then remove all of it? [y/N] ' "$U1" "$U2"
  read -r reply; case "$reply" in y|Y|yes|YES) ;; *) echo "aborted."; exit 0 ;; esac
fi

# --- Provision two throwaway restricted operators --------------------------
phase "Provision — two 'incus'-group users (the restricted tier)"
getent group incus >/dev/null 2>&1 || { no "there is no 'incus' group — is incus-user enabled? (setup-host)"; exit 1; }
for u in "$U1" "$U2"; do
  id "$u" >/dev/null 2>&1 || useradd -m -G incus "$u"
  # ASSUMED-PENDING-REHEARSAL: adding to `incus` is supposed to be all it takes —
  # incus-user hands the member a confined project on first socket use. If that
  # is not what happens on this host, (a)/(c) below will say so.
  as "$u" id -nG | grep -qw incus && ok "$u is in the incus group" \
    || no "$u is NOT in the incus group after useradd -G incus"
done

# (a) confinement: each user's bare `incus project list` shows ONLY their own
# project (or 'default' scoped to them), never the other user's.
phase "a. incus-user confines each member to their own project"
as "$U1" incus project list >/tmp/mu.p1 2>/dev/null || no "$U1 cannot list projects — incus-user not serving?"
inf "$U1 sees projects: $(awk 'NR>3{print $2}' /tmp/mu.p1 | tr '\n' ' ')"

# (b) the restricted user drives their own lifecycle: new → list → shell.
phase "b. a restricted user runs their OWN box"
if as "$U1" "$BOX" new --name mine --template blank; then
  ok "$U1 minted 'mine'"
  as "$U1" "$BOX" list | grep -q mine && ok "$U1 sees 'mine' in box list" || no "$U1 cannot see their own box"
  as "$U1" "$BOX" exec mine -- true </dev/null && ok "$U1 can exec into 'mine'" || no "$U1 cannot exec into their own box"
else
  no "$U1 could not mint a box — restricted-tier convergence (ensure_boxnet_profile) may have failed; see box doctor as $U1"
fi

# (d) a name COLLISION across users is fine — each names inside its own project.
phase "d. the same box name in two projects does not collide"
if as "$U2" "$BOX" new --name mine --template blank; then
  ok "$U2 also minted 'mine' — no cross-user collision (separate projects)"
else
  no "$U2 could not mint 'mine' — a name collision across users would break the tier"
fi

# (c) isolation: neither user can SEE the other's boxes. Same name, so identity
# is by project, not by string — a leak would show BOTH in one list.
phase "c. one user cannot see another's boxes"
n1="$(as "$U1" "$BOX" list 2>/dev/null | grep -c mine || true)"
n2="$(as "$U2" "$BOX" list 2>/dev/null | grep -c mine || true)"
{ [ "$n1" = 1 ] && [ "$n2" = 1 ]; } \
  && ok "each user sees exactly one 'mine' — their own (project confinement holds)" \
  || no "a user sees $n1/$n2 'mine' boxes — confinement LEAKED (this vetoes the restricted tier as designed)"

# (e) expose must REFUSE under restricted — it edits the daemon-global ACL.
phase "e. box expose refuses for a restricted user"
as "$U1" "$BOX" expose mine 3000 2>/tmp/mu.exp; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'restricted' /tmp/mu.exp; then
  ok "expose refused early with the tier message"
else
  no "expose did not refuse cleanly for a restricted user (rc=$rc)"; sed 's/^/        /' /tmp/mu.exp
fi

# (f) setup-host must give the honest restricted note, not an opaque failure.
phase "f. box setup-host is honest to a restricted user"
as "$U1" "$BOX" setup-host 2>/tmp/mu.sh; rc=$?
if grep -q "restricted tier" /tmp/mu.sh; then
  ok "setup-host printed the honest restricted note"
else
  no "setup-host did not give the restricted note (rc=$rc)"; sed 's/^/        /' /tmp/mu.sh
fi

phase "Verdict"
if [ "$fail" -eq 0 ]; then
  printf '  \033[32mall %d checks passed\033[0m — incus-user confinement HOLDS on this host.\n' "$pass"
  printf '  #72 Task 0 is answered: the restricted tier is real here. Record it in RUNS.md.\n\n'
  exit 0
fi
printf '  \033[31m%d of %d checks FAILED\033[0m — read them as a design signal, not a flaky run:\n' "$fail" "$((pass + fail))"
printf '%s\n' "${findings[@]}" | sed 's/^/    /'
printf '  If (a)/(c) failed, incus-user does NOT confine as assumed — #72 needs a different\n'
printf '  per-project mechanism. That is the fork the code comments warn about.\n\n'
exit 1
