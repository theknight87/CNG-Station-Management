#!/usr/bin/env bash
# Full verification gate. CLAUDE.md §7a: the EXIT CODE is the authority.
#
# Nothing here greps for success. Each command runs directly, its status is
# captured immediately, and the script exits non-zero if any step failed. Test
# counts are extracted only to be REPORTED and compared against the baseline —
# never to decide pass or fail.
set -uo pipefail

fail=0
line() { printf '%-34s %s\n' "$1" "$2"; }

run() { # run <label> <command...>
  local label="$1"; shift
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ $status -ne 0 ]; then
    fail=1
    line "$label" "FAIL (exit $status)"
    printf '%s\n' "$out" | tail -25
  else
    line "$label" "PASS (exit 0)"
  fi
  printf '%s' "$out" > "/tmp/verify-${label// /-}.log"
  return $status
}

echo "=== build / lint / tests (exit code is the verdict) ==="
run "build"  npm run build
run "lint"   npx eslint src dev --max-warnings=0
run "tests"  npx vitest run
run "brand"  node scripts/verify-brand.mjs
# Run the import/dry-run regression suite in its own right as well as inside the
# full run, so a failure there is named rather than buried in a total.
run "import suite" npx vitest run src/import

# Counts are reported, not used as the verdict.
tests_log=/tmp/verify-tests.log
if [ -f "$tests_log" ]; then
  line "frontend tests" "$(grep -oE 'Tests +[0-9]+ (passed|failed)[^\n]*' "$tests_log" | tail -1)"
  line "test files" "$(grep -oE 'Test Files +[0-9]+ (passed|failed)[^\n]*' "$tests_log" | tail -1)"
fi

echo "=== SQL suites (psql exit code is the verdict) ==="
DB="${VERIFY_DB:-cng_p11}"
sudo -n -u postgres psql -q -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB" >/dev/null 2>&1
mig_fail=0
for f in supabase/migrations/*.sql; do
  if ! sudo -n -u postgres psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f" >/dev/null 2>&1; then
    echo "MIGRATION FAILED: $f"; mig_fail=1; fail=1
  fi
done
[ $mig_fail -eq 0 ] && line "migrations from zero" "PASS ($(ls supabase/migrations/*.sql | wc -l) applied)"

# REPORT CONTRACT. Compares every column the report specs ask for against the
# columns the views actually expose, against the database just built. Neither
# the SQL suites nor the frontend tests can see this boundary, and a report spec
# naming a column no view has reached production once (Prompt 20B).
run "report contract" npx tsx scripts/verify-report-contract.mjs "$DB"

# Minimum assertion counts, from the CLAUDE.md baseline table. A suite that
# runs but asserts nothing (a failed connection, a renamed file, a truncated
# run) must FAIL rather than report a cheerful zero - that is precisely the
# silent coverage loss this gate exists to stop.
declare -A MIN=( [schema_scenarios]=344 [rls_authorization]=703 [rls_initplan_perf]=25 )

for suite in schema_scenarios rls_authorization rls_initplan_perf; do
  out="$(sudo -n -u postgres psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "supabase/tests/$suite.sql" 2>&1)"
  count="$(printf '%s' "$out" | grep -c 'PASS ')"
  min="${MIN[$suite]}"
  if printf '%s' "$out" | grep -q 'FAILED:'; then
    fail=1; line "sql $suite" "FAIL (assertion failed)"
    printf '%s\n' "$out" | grep 'FAILED:' | head -5
  elif [ "$count" -lt "$min" ]; then
    fail=1; line "sql $suite" "FAIL ($count assertions, baseline is $min - investigate before PASS)"
  else
    line "sql $suite" "PASS ($count assertions, baseline $min)"
  fi
done

# ---------------------------------------------------------------------------
# UPGRADE REPLAY. Replaying from zero proves the migrations are internally
# consistent; it does NOT prove that the hosted database, which is at 49, can
# take the new one. So the upgrade path is replayed separately: stop at the
# deployed count, then apply what this branch adds, exactly as production would.
# ---------------------------------------------------------------------------
UDB="${VERIFY_UPGRADE_DB:-cng_upgrade}"
sudo -n -u postgres psql -q -c "DROP DATABASE IF EXISTS $UDB" -c "CREATE DATABASE $UDB" >/dev/null 2>&1
up_fail=0
# Migration files present in the repository but NOT applied to production.
# Production is no longer a file-order prefix: 0055 and everything after it are
# deployed while 0054 is not (Prompt 27A). So the base is "every file except
# these" and the upgrade replays exactly these. Update this list after each
# deployment, checked against supabase_migrations.schema_migrations.
UNDEPLOYED_MIGRATIONS=()
is_undeployed() { local b; b="$(basename "$1")"; for u in "${UNDEPLOYED_MIGRATIONS[@]}"; do [ "$b" = "$u" ] && return 0; done; return 1; }
base_count=0
for f in supabase/migrations/*.sql; do
  is_undeployed "$f" && continue
  sudo -n -u postgres psql -d "$UDB" -v ON_ERROR_STOP=1 -q -f "$f" >/dev/null 2>&1 \
    || { echo "BASE MIGRATION FAILED: $f"; up_fail=1; break; }
  base_count=$((base_count + 1))
done
DEPLOYED_MIGRATIONS=$base_count
if [ $up_fail -eq 0 ]; then
  line "production-equivalent base" "PASS ($DEPLOYED_MIGRATIONS applied)"
  # The upgrade path from the CURRENT production migration count: everything the
  # repository has BEYOND what is deployed, derived rather than hard-coded. An
  # empty set reports "nothing pending" and must never run psql on a literal glob.
  pending=()
  for u in "${UNDEPLOYED_MIGRATIONS[@]}"; do
    [ -f "supabase/migrations/$u" ] || { echo "UNDEPLOYED FILE MISSING: $u"; up_fail=1; fail=1; }
    pending+=("supabase/migrations/$u")
  done
  if [ ${#pending[@]} -eq 0 ]; then
    line "upgrade replay" "PASS (nothing pending beyond the deployed count)"
  else
    for f in "${pending[@]}"; do
      if sudo -n -u postgres psql -d "$UDB" -v ON_ERROR_STOP=1 -q -f "$f" >/dev/null 2>&1; then
        line "upgrade $(basename "$f" .sql)" "PASS (exit 0)"
      else
        echo "UPGRADE FAILED: $f"; up_fail=1; fail=1; break
      fi
    done
  fi
fi
[ $up_fail -ne 0 ] && fail=1

# The upgraded database must pass the same suites as one built from zero: an
# upgrade that "works" but leaves different behaviour behind is not an upgrade.
if [ $up_fail -eq 0 ]; then
  for suite in schema_scenarios rls_authorization rls_initplan_perf; do
    out="$(sudo -n -u postgres psql -d "$UDB" -v ON_ERROR_STOP=1 -q -f "supabase/tests/$suite.sql" 2>&1)"
    count="$(printf '%s' "$out" | grep -c 'PASS ')"
    if printf '%s' "$out" | grep -q 'FAILED:'; then
      fail=1; line "upgraded $suite" "FAIL (assertion failed)"
      printf '%s\n' "$out" | grep 'FAILED:' | head -5
    elif [ "$count" -lt "${MIN[$suite]}" ]; then
      fail=1; line "upgraded $suite" "FAIL ($count assertions, baseline ${MIN[$suite]})"
    else
      line "upgraded $suite" "PASS ($count assertions)"
    fi
  done
fi

echo
if [ $fail -ne 0 ]; then echo "VERIFICATION FAILED"; exit 1; fi
echo "VERIFICATION PASSED"
