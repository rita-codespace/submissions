#!/usr/bin/env bash
# Creates (or finds) a student's project repository "<login>-<name>" and
# invites the student with push permission.
#
# Identity comes only from github.event.issue.user. The one value read from the
# issue body is the requested repository name. It arrives through an
# environment variable (never interpolated into the script) and must match
# ^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$ before it is used anywhere.
#
# Ownership: every repository this script creates carries
# "[registrant-id:<numeric user id>] [project:<name>]" in its description, set
# in the same API call that creates it. Changing a description needs Maintain
# or Admin, and students only get Write, so a student cannot forge or move the
# marker. Access is granted only to a repository whose marker matches the
# issue author's numeric id and the requested name. A name match alone is
# never enough.
#
# Required env: GH_TOKEN (GitHub App installation token), ORG, STUDENT_LOGIN,
#               STUDENT_ID, STUDENT_TYPE, ISSUE_BODY
# Outputs (GITHUB_OUTPUT): result=created|existing|failed, repo_name, repo_url,
#               invite_status=invited|already_collaborator, error_code, error_detail
set -euo pipefail

MAX_REPOS="${MAX_REPOS:-5}"  # repositories one student may register
MAX_ATTEMPTS="${MAX_ATTEMPTS:-4}"
MAX_WAIT="${MAX_WAIT:-60}"   # longest rate-limit wait (seconds) before giving up
SLEEP="${SLEEP:-sleep}"
OUT="${GITHUB_OUTPUT:-/dev/null}"

log() { printf '%s\n' "$*" >&2; }

output() {
  # Single-line values only; strip CR/LF so a value cannot add extra outputs.
  printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr -d '\r\n' | cut -c1-300)" >> "$OUT"
}

fail() { # fail CODE DETAIL
  output result failed
  output error_code "$1"
  output error_detail "$2"
  log "::error::$1: $(printf '%s' "$2" | tr -d '\r\n%')"
  exit 1
}

# api METHOD PATH [gh api flags...]
# Sets API_STATUS (000 = no HTTP response), API_BODY, API_RATE_LIMITED (0/1).
# Retries rate limits (when the wait is short) and 5xx/network errors.
api() {
  local method=$1 path=$2 attempt raw headers wait retry_after remaining reset
  shift 2
  for ((attempt = 1; ; attempt++)); do
    raw=$(gh api -i -X "$method" "$path" "$@" 2>/dev/null) || true
    raw=${raw//$'\r'/}
    API_STATUS=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' <<<"$raw")
    [[ -n $API_STATUS ]] || API_STATUS=000
    headers=$(sed -n '2,/^$/p' <<<"$raw" | tr 'A-Z' 'a-z')
    API_BODY=$(sed '1,/^$/d' <<<"$raw")
    API_RATE_LIMITED=0

    retry_after=$(sed -n 's/^retry-after: *\([0-9]*\).*/\1/p' <<<"$headers")
    remaining=$(sed -n 's/^x-ratelimit-remaining: *\([0-9]*\).*/\1/p' <<<"$headers")
    reset=$(sed -n 's/^x-ratelimit-reset: *\([0-9]*\).*/\1/p' <<<"$headers")

    wait=""
    if [[ $API_STATUS == 429 ]] ||
       { [[ $API_STATUS == 403 ]] &&
         { [[ $remaining == 0 || -n $retry_after ]] || grep -qi 'rate limit' <<<"$API_BODY"; }; }; then
      API_RATE_LIMITED=1
      if [[ -n $retry_after ]]; then
        wait=$retry_after
      elif [[ $remaining == 0 && -n $reset ]]; then
        wait=$(( reset - $(date +%s) + 1 ))
        ((wait > 0)) || wait=1
      else
        wait=60   # secondary limit without Retry-After: GitHub asks for >= 1 minute
      fi
    elif [[ $API_STATUS == 000 || $API_STATUS == 5* ]]; then
      wait=$(( attempt * 5 ))
    fi

    [[ -n $wait ]] || return 0
    if ((attempt >= MAX_ATTEMPTS || wait > MAX_WAIT)); then
      return 0
    fi
    log "HTTP $API_STATUS on $method $path; retrying in ${wait}s (attempt $attempt/$MAX_ATTEMPTS)"
    "$SLEEP" "$wait"
  done
}

api_message() { jq -r '.message // empty' 2>/dev/null <<<"$API_BODY" | head -1; }

# fail_api CONTEXT: fail with an error code that separates rate limits from
# permission problems (both can be 403) and from missing resources.
fail_api() {
  local kind
  if ((API_RATE_LIMITED)); then kind=rate_limited
  else
    case $API_STATUS in
      401) kind=unauthorized ;;
      403) kind=forbidden ;;
      404) kind=not_found ;;
      422) kind=invalid ;;
      000) kind=network_error ;;
      5*)  kind=server_error ;;
      *)   kind="http_$API_STATUS" ;;
    esac
  fi
  fail "${1}_${kind}" "HTTP $API_STATUS on ${1//_/ }: $(api_message)"
}


id_marker() { printf '[registrant-id:%s]' "$STUDENT_ID"; }
project_marker() { printf '[project:%s]' "$name"; }

# owned_by_student: true when $API_BODY (a repository) carries the student's
# id marker and the requested project marker.
owned_by_student() {
  jq -e --arg id "$(id_marker)" --arg p "$(project_marker)" \
    '(.description // "") | contains($id) and contains($p)' >/dev/null 2>&1 <<<"$API_BODY"
}

# --- 1. who is asking ---------------------------------------------------------

[[ $STUDENT_TYPE == User ]] ||
  fail not_a_user "Issue author type is '$STUDENT_TYPE'; only personal accounts can register."
[[ $STUDENT_ID =~ ^[0-9]+$ && $STUDENT_LOGIN =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] ||
  fail invalid_user "Issue author login or id is malformed."

api GET "user/$STUDENT_ID"
[[ $API_STATUS == 200 ]] || fail_api lookup_user
[[ $(jq -r '.type' <<<"$API_BODY") == User ]] ||
  fail not_a_user "Account $STUDENT_ID is not a personal user account."
# Use the account's current login (it may have changed since the issue was opened).
login=$(jq -r '.login' <<<"$API_BODY")
[[ $login =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || fail invalid_user "Unexpected login format."
log "Registering @$login (id $STUDENT_ID)"

# --- 2. requested repository name --------------------------------------------
# First non-empty line under the form's "### 저장소 이름" heading.

name=$(printf '%s\n' "${ISSUE_BODY:-}" | tr -d '\r' | awk '
  /^### / { if (found) exit; if (index($0, "### 저장소 이름") == 1) found = 1; next }
  found && NF { print; exit }')
name=$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')
[[ $name =~ ^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$ ]] ||
  fail invalid_repo_name "저장소 이름은 영문 소문자·숫자·하이픈(-)만 사용해 2~40자로 적어야 하며, 하이픈으로 시작하거나 끝날 수 없습니다."

# --- 3. this student's repositories (by numeric id) --------------------------

repo=""
owned=()
page=1
while :; do
  api GET "orgs/$ORG/repos?type=all&per_page=100&page=$page"
  [[ $API_STATUS == 200 ]] || fail_api list_repos
  while IFS= read -r line; do
    [[ -n $line ]] && owned+=("$line")
  done < <(jq -r --arg id "$(id_marker)" \
    '.[] | select((.description // "") | contains($id)) | .name' <<<"$API_BODY")
  [[ -z $repo ]] && repo=$(jq -r --arg id "$(id_marker)" --arg p "$(project_marker)" '
      [.[] | select((.description // "") | contains($id) and contains($p)) | .name]
      | first // empty' <<<"$API_BODY")
  (( $(jq length <<<"$API_BODY") >= 100 )) || break
  page=$((page + 1))
done

result=""
if [[ -n $repo ]]; then
  result=existing
  log "Found existing repository $ORG/$repo for id $STUDENT_ID, project $name"
else
  ((${#owned[@]} < MAX_REPOS)) ||
    fail repo_limit_reached "한 계정당 최대 ${MAX_REPOS}개까지 등록할 수 있습니다. 현재 등록된 Repository: ${owned[*]}"

  # --- 4. create it, or verify a same-name repository really is ours ----------
  repo=$(printf '%s-%s' "$login" "$name" | tr 'A-Z' 'a-z')

  verify_same_name() {
    if owned_by_student; then
      result=existing
    else
      fail name_conflict "$ORG/$repo already exists but was not created by this automation for this account and project. No access was granted; an organization owner must review it."
    fi
  }

  api GET "repos/$ORG/$repo"
  case $API_STATUS in
    200) verify_same_name ;;
    404)
      api POST "orgs/$ORG/repos" \
        -f name="$repo" \
        -f description="Project repository of @$login $(id_marker) $(project_marker)" \
        -f visibility=public \
        -F has_issues=true -F has_wiki=false -F has_projects=false -F auto_init=true
      case $API_STATUS in
        201) result=created ;;
        422)
          # Usually a concurrent run for the same request created it first.
          api GET "repos/$ORG/$repo"
          [[ $API_STATUS == 200 ]] || fail_api create_repo
          verify_same_name ;;
        *) fail_api create_repo ;;
      esac ;;
    *) fail_api check_repo ;;
  esac
  log "Repository $ORG/$repo: $result"
fi

output repo_name "$repo"
output repo_url "https://github.com/$ORG/$repo"

# --- 4. invite the student with push (Write) only ----------------------------
# PUT is idempotent: re-running updates the pending invitation instead of
# creating a second one, so a failed invite is fixed by re-running the job.

api PUT "repos/$ORG/$repo/collaborators/$login" -f permission=push
case $API_STATUS in
  201) output invite_status invited ;;
  204) output invite_status already_collaborator ;;
  *) fail_api invite ;;
esac

output result "$result"
log "Done: $result, invitation status recorded."
