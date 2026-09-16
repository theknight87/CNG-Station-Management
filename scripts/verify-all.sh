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

# Minimum assertion counts, from the CLAUDE.md baseline table. A suite that
# runs but asserts nothing (a failed connection, a renamed file, a truncated
# run) must FAIL rather than report a cheerful zero - that is precisely the
# silent coverage loss this gate exists to stop.
declare -A MIN=( [schema_scenarios]=146 [rls_authorization]=332 )

for suite in schema_scenarios rls_authorization; do
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

echo
if [ $fail -ne 0 ]; then echo "VERIFICATION FAILED"; exit 1; fi
echo "VERIFICATION PASSED"
