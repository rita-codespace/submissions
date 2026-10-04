#!/usr/bin/env bash
# Runs the registration scripts against a fake `gh` (tests/fake-gh/gh).
# Usage: bash tests/run-tests.sh   (needs bash and jq)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REGISTER="$ROOT/.github/scripts/register-student.sh"
REPORT="$ROOT/.github/scripts/report-result.sh"
export PATH="$ROOT/tests/fake-gh:$PATH"

passed=0 failed=0
current=""

# --- helpers -----------------------------------------------------------------

setup() {
  current=$1
  MOCK_DIR=$(mktemp -d)
  export MOCK_DIR
  : > "$MOCK_DIR/calls.log"
  export GITHUB_OUTPUT="$MOCK_DIR/output"
  : > "$GITHUB_OUTPUT"
  export ORG=rita-codespace STUDENT_LOGIN=Alice STUDENT_ID=1001 STUDENT_TYPE=User
  export SLEEP=true MAX_WAIT=60
}

# mock KEY STATUS [BODY] [HEADER...]
mock() {
  local key=$1 status=$2 body=${3:-}
  shift 3 2>/dev/null || shift $#
  { echo "$status"; for h in "$@"; do echo "$h"; done; echo; printf '%s' "$body"; } > "$MOCK_DIR/$key"
}

user_ok() { mock GET_user_1001 200 '{"login":"Alice","id":1001,"type":"User"}'; }
no_repos() { mock "GET_orgs_rita-codespace_repos_type_all_per_page_100_page_1" 200 '[]'; }
repo_json() { printf '{"name":"%s","html_url":"https://github.com/rita-codespace/%s","description":"%s","visibility":"public"}' "$1" "$1" "$2"; }

run_register() { bash "$REGISTER" > "$MOCK_DIR/stdout" 2> "$MOCK_DIR/stderr"; echo $? > "$MOCK_DIR/rc"; }

out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -1; }

check() { # check DESCRIPTION COMMAND...
  if "${@:2}"; then return 0; fi
  echo "  FAIL [$current] $1"
  echo "    stderr: $(tr '\n' ' ' < "$MOCK_DIR/stderr" 2>/dev/null | cut -c1-400)"
  CASE_FAILED=1
}
eq() { [[ $1 == "$2" ]] || { echo "    expected '$2', got '$1'"; return 1; }; }
called() { grep -qF -- "$1" "$MOCK_DIR/calls.log"; }
not_called() { ! grep -qF -- "$1" "$MOCK_DIR/calls.log"; }

finish() {
  if [[ ${CASE_FAILED:-0} == 1 ]]; then failed=$((failed + 1)); else passed=$((passed + 1)); echo "  ok   $current"; fi
  CASE_FAILED=0
  rm -rf "$MOCK_DIR"
}

# --- register-student.sh -----------------------------------------------------

setup "new student gets a public repo and a push invitation"
user_ok; no_repos
mock GET_repos_rita-codespace_phase1-alice 404 '{"message":"Not Found"}'
mock POST_orgs_rita-codespace_repos 201 "$(repo_json phase1-alice 'x [registrant-id:1001]')"
mock PUT_repos_rita-codespace_phase1-alice_collaborators_Alice 201 '{"id":5}'
run_register
check "exit 0" eq "$(cat "$MOCK_DIR/rc")" 0
check "result created" eq "$(out result)" created
check "repo url" eq "$(out repo_url)" https://github.com/rita-codespace/phase1-alice
check "invite pending" eq "$(out invite_status)" invited
check "public visibility requested" called "visibility=public"
check "marker in description" called "[registrant-id:1001]"
check "push permission only" called "permission=push"
finish

setup "duplicate request reuses the repo found by numeric id"
user_ok
mock "GET_orgs_rita-codespace_repos_type_all_per_page_100_page_1" 200 "[$(repo_json phase1-alice 'x [registrant-id:1001]')]"
mock PUT_repos_rita-codespace_phase1-alice_collaborators_Alice 204 ''
run_register
check "exit 0" eq "$(cat "$MOCK_DIR/rc")" 0
check "result existing" eq "$(out result)" existing
check "invite already accepted" eq "$(out invite_status)" already_collaborator
check "no create call" not_called "POST orgs/rita-codespace/repos"
finish

setup "renamed student keeps the repo registered under the old login"
user_ok
mock "GET_orgs_rita-codespace_repos_type_all_per_page_100_page_1" 200 "[$(repo_json phase1-oldname 'x [registrant-id:1001]')]"
mock PUT_repos_rita-codespace_phase1-oldname_collaborators_Alice 201 '{"id":5}'
run_register
check "result existing" eq "$(out result)" existing
check "old repo reused" eq "$(out repo_name)" phase1-oldname
check "no create call" not_called "POST orgs/rita-codespace/repos"
finish

setup "marker of another id is not a match (prefix collision)"
user_ok
mock "GET_orgs_rita-codespace_repos_type_all_per_page_100_page_1" 200 "[$(repo_json phase1-bob 'x [registrant-id:10011]')]"
mock GET_repos_rita-codespace_phase1-alice 404 '{"message":"Not Found"}'
mock POST_orgs_rita-codespace_repos 201 "$(repo_json phase1-alice 'x [registrant-id:1001]')"
mock PUT_repos_rita-codespace_phase1-alice_collaborators_Alice 201 '{}'
run_register
check "result created" eq "$(out result)" created
check "bob's repo untouched" not_called "phase1-bob/collaborators"
finish

setup "same-name repo created for someone else is refused"
user_ok; no_repos
mock GET_repos_rita-codespace_phase1-alice 200 "$(repo_json phase1-alice 'x [registrant-id:999]')"
run_register
check "exit non-zero" eq "$(cat "$MOCK_DIR/rc")" 1
check "result failed" eq "$(out result)" failed
check "error code" eq "$(out error_code)" name_conflict
check "no invitation" not_called "collaborators"
finish

setup "same-name repo without any marker is refused"
user_ok; no_repos
mock GET_repos_rita-codespace_phase1-alice 200 "$(repo_json phase1-alice 'made by hand')"
run_register
check "error code" eq "$(out error_code)" name_conflict
check "no invitation" not_called "collaborators"
finish

setup "concurrent run: create returns 422, repo is ours -> reuse"
user_ok; no_repos
mock GET_repos_rita-codespace_phase1-alice.1 404 '{"message":"Not Found"}'
mock GET_repos_rita-codespace_phase1-alice.2 200 "$(repo_json phase1-alice 'x [registrant-id:1001]')"
mock POST_orgs_rita-codespace_repos 422 '{"message":"Repository creation failed.","errors":[{"message":"name already exists on this account"}]}'
mock PUT_repos_rita-codespace_phase1-alice_collaborators_Alice 201 '{}'
run_register
check "exit 0" eq "$(cat "$MOCK_DIR/rc")" 0
check "result existing" eq "$(out result)" existing
finish

setup "concurrent run: create returns 422, repo is not ours -> refuse"
user_ok; no_repos
mock GET_repos_rita-codespace_phase1-alice.1 404 '{"message":"Not Found"}'
mock GET_repos_rita-codespace_phase1-alice.2 200 "$(repo_json phase1-alice 'x [registrant-id:7]')"
mock POST_orgs_rita-codespace_repos 422 '{"message":"Repository creation failed."}'
run_register
check "error code" eq "$(out error_code)" name_conflict
check "no invitation" not_called "collaborators"
finish

setup "invite failure after creation keeps repo url and fails"
user_ok; no_repos
mock GET_repos_rita-codespace_phase1-alice 404 '{"message":"Not Found"}'
mock POST_orgs_rita-codespace_repos 201 "$(repo_json phase1-alice 'x [registrant-id:1001]')"
mock PUT_repos_rita-codespace_phase1-alice_collaborators_Alice 403 '{"message":"Must have admin rights to Repository."}'
run_register
check "exit non-zero" eq "$(cat "$MOCK_DIR/rc")" 1
check "result failed" eq "$(out result)" failed
check "error code" eq "$(out error_code)" invite_forbidden
check "repo url still reported" eq "$(out repo_url)" https://github.com/rita-codespace/phase1-alice
finish

setup "primary rate limit is retried after reset"
user_ok; no_repos
mock GET_repos_rita-codespace_phase1-alice.1 403 '{"message":"API rate limit exceeded"}' "X-Ratelimit-Remaining: 0" "X-Ratelimit-Reset: $(( $(date +%s) + 5 ))"
mock GET_repos_rita-codespace_phase1-alice.2 404 '{"message":"Not Found"}'
mock POST_orgs_rita-codespace_repos 201 "$(repo_json phase1-alice 'x [registrant-id:1001]')"
mock PUT_repos_rita-codespace_phase1-alice_collaborators_Alice 201 '{}'
run_register
check "result created" eq "$(out result)" created
finish

setup "long rate limit fails as rate_limited, not as permission error"
user_ok
mock "GET_orgs_rita-codespace_repos_type_all_per_page_100_page_1" 429 '{"message":"slow down"}' "Retry-After: 3600"
run_register
check "error code" eq "$(out error_code)" list_repos_rate_limited
finish

setup "plain 403 is a permission error"
user_ok
mock "GET_orgs_rita-codespace_repos_type_all_per_page_100_page_1" 403 '{"message":"Resource not accessible by integration"}' "X-Ratelimit-Remaining: 4000"
run_register
check "error code" eq "$(out error_code)" list_repos_forbidden
finish

setup "organization or bot authors are rejected before any API call"
export STUDENT_TYPE=Organization
run_register
check "error code" eq "$(out error_code)" not_a_user
check "no api calls" eq "$(wc -l < "$MOCK_DIR/calls.log" | tr -d ' ')" 0
finish

setup "malformed login is rejected"
export STUDENT_LOGIN='x;rm -rf /'
run_register
check "error code" eq "$(out error_code)" invalid_user
check "no api calls" eq "$(wc -l < "$MOCK_DIR/calls.log" | tr -d ' ')" 0
finish

setup "user id that does not resolve to a User is rejected"
mock GET_user_1001 200 '{"login":"Alice","id":1001,"type":"Bot"}'
run_register
check "error code" eq "$(out error_code)" not_a_user
check "no create" not_called "POST"
finish

setup "listing walks every page"
user_ok
page1="[$(for i in $(seq 1 100); do printf '%s,' "$(repo_json "proj$i" '')"; done | sed 's/,$//')]"
mock "GET_orgs_rita-codespace_repos_type_all_per_page_100_page_1" 200 "$page1"
mock "GET_orgs_rita-codespace_repos_type_all_per_page_100_page_2" 200 "[$(repo_json phase1-alice 'x [registrant-id:1001]')]"
mock PUT_repos_rita-codespace_phase1-alice_collaborators_Alice 204 ''
run_register
check "found on page 2" eq "$(out result)" existing
finish

# --- report-result.sh --------------------------------------------------------

setup_report() {
  setup "$1"
  export ISSUE_NUMBER=7 GITHUB_REPOSITORY=rita-codespace/submissions RUN_URL=https://example/run
  export TOKEN_OUTCOME=success REGISTER_OUTCOME=success
  export RESULT="" REPO_NAME="" REPO_URL="" INVITE_STATUS="" ERROR_CODE="" ERROR_DETAIL=""
}
run_report() { bash "$REPORT" > "$MOCK_DIR/stdout" 2> "$MOCK_DIR/stderr"; echo $? > "$MOCK_DIR/rc"; }
comment_has() { grep -qF -- "$1" "$MOCK_DIR/comment.md"; }

setup_report "report: created repo with pending invitation"
export RESULT=created REPO_NAME=phase1-alice REPO_URL=https://github.com/rita-codespace/phase1-alice INVITE_STATUS=invited
run_report
check "exit 0" eq "$(cat "$MOCK_DIR/rc")" 0
check "repo link" comment_has "https://github.com/rita-codespace/phase1-alice"
check "invitation link" comment_has "https://github.com/rita-codespace/phase1-alice/invitations"
check "issue closed" called "issue close 7"
check "no failure label" not_called "registration-failed"
finish

setup_report "report: failure keeps issue open with label and reason"
export RESULT=failed ERROR_CODE=name_conflict ERROR_DETAIL="phase1-alice exists" REGISTER_OUTCOME=failure
run_report
check "reason shown" comment_has "name_conflict"
check "label added" called "--add-label registration-failed"
check "not closed" not_called "issue close"
finish

setup_report "report: token step failed"
export TOKEN_OUTCOME=failure REGISTER_OUTCOME=skipped
run_report
check "auth error explained" comment_has "app_token_failed"
check "label added" called "--add-label registration-failed"
finish

setup_report "report: script crashed without a result"
export REGISTER_OUTCOME=failure
run_report
check "generic failure" comment_has "unexpected_error"
finish

echo
echo "passed: $passed, failed: $failed"
((failed == 0))
