# rita-codespace 프로젝트 Repository 등록

이 Repository는 소스코드를 올리는 곳이 아니라 **본인 전용 프로젝트 Repository를 신청하는 접수처**입니다.

## 등록 방법

1. GitHub에 로그인합니다. Organization 가입은 필요 없습니다.
2. 👉 **[등록 Issue 작성하기](https://github.com/rita-codespace/submissions/issues/new?template=register.yml)**
3. 프로젝트명, 저장소 이름(영문 소문자·숫자·하이픈), 간단한 설명을 적고 **Create**를 누릅니다.
4. 몇 분 안에 Issue 댓글로 결과가 안내됩니다.
   - `rita-codespace/<본인 GitHub ID>-<저장소 이름>` Repository가 **Public**으로 생성됩니다.
   - 댓글의 초대 링크에서 **Accept invitation**을 눌러야 Push할 수 있습니다 (초대는 7일 후 만료됩니다).

## 알아 둘 점

- GitHub ID는 Issue 작성 계정에서 자동으로 확인합니다. 다른 사람 대신 등록할 수 없습니다.
- 본인 Repository에는 **Write(push)** 권한만 부여됩니다. 다른 학생의 Repository는 열람만 가능합니다.
- 프로젝트마다 저장소 이름을 다르게 적으면 계정당 최대 5개까지 만들 수 있습니다. 같은 이름으로 다시 신청하면 기존 Repository를 안내하며, 초대가 만료되었다면 새 초대가 발송됩니다.
- 모든 Repository는 공개됩니다. 비밀번호, API 키, 개인정보를 커밋하지 마세요.
- 등록이 실패하면 Issue에 오류 사유가 댓글로 남고 관리자가 확인합니다.

---

### 관리자용 메모

- 자동화: [`.github/workflows/create-student-repo.yml`](.github/workflows/create-student-repo.yml) → [`.github/scripts/register-student.sh`](.github/scripts/register-student.sh)
- 인증: GitHub App (Repository 권한 Administration: Read & write, Metadata: Read, 설치 범위 All repositories). Actions Variable `APP_CLIENT_ID`, Secret `APP_PRIVATE_KEY`.
- 소유자 식별: 생성된 Repository 설명(description)의 `[registrant-id:<숫자 User ID>] [project:<저장소 이름>]` 표식. Write 권한으로는 설명을 수정할 수 없으므로 학생이 위조할 수 없습니다. **이 표식을 지우거나 바꾸면 해당 학생의 재등록(재초대)이 거부되고, 계정당 개수 제한에서도 빠집니다.** 개수 제한은 Workflow의 `MAX_REPOS`로 바꿀 수 있습니다.
- 실패한 등록 Issue는 `registration-failed` 라벨이 붙은 채 열려 있습니다. 원인 해결 후 해당 Workflow run을 **Re-run**하면 이어서 처리됩니다.
- 문제 있는 Repository는 Owner가 직접 삭제합니다.
- 스크립트 테스트: `bash tests/run-tests.sh` (bash, jq 필요, 실제 API 호출 없음)
