#!/usr/bin/env bash
# Posts the registration result to the issue (runs with the workflow's
# GITHUB_TOKEN, never with the GitHub App token).
#
# Successful or duplicate registrations are closed. Failures stay open with the
# "registration-failed" label so an owner can find them.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, ISSUE_NUMBER, RUN_URL,
#   TOKEN_OUTCOME, REGISTER_OUTCOME (step outcomes), and the register step's
#   outputs: RESULT, REPO_NAME, REPO_URL, INVITE_STATUS, ERROR_CODE, ERROR_DETAIL
set -euo pipefail

body=$(mktemp)

if [[ $TOKEN_OUTCOME != success ]]; then
  RESULT=failed
  ERROR_CODE=app_token_failed
  ERROR_DETAIL="GitHub App 인증 토큰을 발급하지 못했습니다 (APP_CLIENT_ID / APP_PRIVATE_KEY / App 설치 상태 확인 필요)."
elif [[ -z ${RESULT:-} ]]; then
  RESULT=failed
  ERROR_CODE=unexpected_error
  ERROR_DETAIL="등록 스크립트가 결과를 남기지 못하고 종료되었습니다 (step outcome: ${REGISTER_OUTCOME:-unknown})."
fi

case $RESULT in
  created|existing)
    if [[ $RESULT == created ]]; then
      headline="✅ 프로젝트 Repository가 생성되었습니다."
    else
      headline="ℹ️ 이미 등록된 Repository가 있어 새로 만들지 않았습니다. (중복 등록 요청)"
    fi
    if [[ ${INVITE_STATUS:-} == invited ]]; then
      invite="**다음 단계: 초대를 수락해야 Push할 수 있습니다.**
아래 링크에서 **Accept invitation**을 눌러 주세요. 초대는 7일 후 만료되며, 만료되면 등록 Issue를 다시 작성하면 새 초대가 발송됩니다.
👉 ${REPO_URL}/invitations"
    else
      invite="이 계정은 이미 해당 Repository에 접근 권한이 있습니다. 바로 Push할 수 있습니다."
    fi
    cat > "$body" <<EOF
${headline}

- Repository: ${REPO_URL}
- 권한: **Write (push)**: 본인 Repository만 수정할 수 있으며, 다른 학생의 Repository는 열람만 가능합니다.
- 공개 범위: **Public** (비밀번호·API 키 등 민감정보를 올리지 마세요)

${invite}

<!-- registration-result: ${RESULT} repo=${REPO_NAME} -->
EOF
    gh issue comment "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --body-file "$body"
    gh issue close "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --reason completed
    ;;
  *)
    repo_line=""
    if [[ -n ${REPO_URL:-} ]]; then
      repo_line="- Repository: ${REPO_URL} (생성은 되었지만 초대 등 이후 단계가 완료되지 않았습니다)"
    fi
    cat > "$body" <<EOF
❌ Repository 등록을 완료하지 못했습니다.

- 오류 코드: \`${ERROR_CODE:-unknown}\`
- 사유: ${ERROR_DETAIL:-알 수 없음}
${repo_line}

관리자가 원인을 확인한 뒤 이 Issue의 Workflow를 다시 실행하면 이어서 처리됩니다 (이미 만든 Repository는 중복 생성되지 않습니다).
\`rate_limited\` 오류라면 잠시 후 등록 Issue를 새로 작성해도 됩니다.

실행 로그: ${RUN_URL}

<!-- registration-result: failed code=${ERROR_CODE:-unknown} -->
EOF
    gh issue comment "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --body-file "$body"
    gh issue edit "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --add-label registration-failed
    ;;
esac
