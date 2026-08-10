# Phase 2 verification

- 장비: `acceptance-mac`(공개용 역할명, GUI 사용자 컨텍스트)
- 검증 시각: 2026-08-10T15:08:33Z 이전
- 범위: Foundation core, SwiftUI app, 지원 CLI, dependency-free Swift self-test
- 추가 설치: 없음. 기존 Command Line Tools의 Swift 6.0.3만 사용

## 결과

`scripts/run-self-tests.sh`가 다음 19개 계약을 모두 통과했습니다.

1. 새 설치는 고정된 격리 머신 두 대와 mode 0600 원장을 만듦
2. 두 번째 apply는 create/delete를 반복하지 않음
3. 두 설치기 인스턴스가 겹치면 두 번째는 OrbStack 호출 전에 transaction busy로 중단
4. 무소유 동명 충돌은 변경 없이 fail-closed
5. 첫 머신 소유 확인 뒤 중단된 설치 재개
6. 정의된 일곱 failure point 각각에서 두 번째 실행이 중복 create/delete 없이 완료
7. create child 실패 뒤 pending owned record 재개
8. pending record에 owner marker가 없으면 adopt/delete 없이 중단
9. truncate된 state는 OrbStack 변경 없이 중단
10. 미래 schema state는 OrbStack 변경 없이 중단
11. schema 1의 기존 원장은 새 deletion journal 필드 없이도 읽음
12. 소유 표식이 바뀐 rollback은 delete 0
13. 소유 rollback 단위계약은 검증된 record ID 두 개만 삭제
14. delete가 exit 0이어도 ID·이름이 남아 있으면 state를 보존하고 다음 rollback에서 재개
15. 실제 삭제 직후 state 갱신 전 중단돼도 pending deletion journal로 재개
16. rollback command failure 뒤에도 recovery pending 진단을 ID·nonce 없이 mode 0600으로 생성
17. child stderr의 token·사용자 경로를 사용자 오류에 노출하지 않음
18. 지원 진단 JSON은 install ID·record ID·owner nonce를 제외하고 mode 0600으로 기록
19. OrbStack app 내부 CLI와 공증·bundle ID·Team ID·호환 버전을 확인

최종 출력은 `Self-test: 19 passed, 0 failed`였습니다. 각 테스트는 `/fake/orb`만 사용하며 실제 OrbStack CLI가
호출되지 않았음을 함께 검사합니다.

## 계획 리뷰로 반영한 단순화

- 사용자는 `설치 시작`을 한 번 더 누르지 않습니다. 앱을 열면 `app-launch` 영수증을 남기고 즉시 시작합니다.
- 실패했을 때만 `다시 시도` 버튼을 사용합니다.
- 지원 진단은 allowlist 구조체로 새 JSON을 만들며 원본 state나 전체 명령 출력을 복사하지 않습니다.
- OrbStack 2.2.1은 도움말과 달리 정지된 머신도 record ID 삭제에서 nil-pointer panic과 code 2를 냅니다. 이름 삭제는
  경쟁 구간에서 다른 머신을 오삭제할 수 있어 fallback으로 쓰지 않습니다. 제품은 record ID 삭제만 시도해 현재
  버전에서 fail-closed하며, V12는 OrbStack 업그레이드 뒤 별도 acceptance가 필요한 release blocker입니다.
