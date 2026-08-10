# Phase 5 — prototype PR gate

## 게시 판정

이 변경은 **Mac mini 03 내부 프로토타입과 실패 폐쇄형 core의 병합 후보**입니다. 일반 사용자가 내려받는 완성
설치기, OrbStack 자동 설치기 또는 release-ready Mac 경로로 게시하지 않습니다.

## 포함 범위

- 사람이 앱을 한 번 열면 자동 시작하는 SwiftUI `K-AI 설치.app`
- `probe → plan → apply → verify` 공통 core와 검증용 CLI
- 앱 소유 머신만 다루는 owner/state/record 3자 대조
- transaction lock, atomic state, pending create/delete journal, redacted diagnostics
- Mac 앱 build, 19개 dependency-free self-test, 격리 검사, 7-target 시크릿 검사와 CI
- Mac mini 03 실기 증거와 완료 화면

## 병합 뒤에도 남는 blocker

1. 최종 app SHA `0a04af…` 자체의 clean-create V6 receipt가 없습니다. clean-create producer는 이전 SHA
   `1c9d64…`였고 이후 안전성 보강은 기존 머신에서 멱등·재시작·격리로 확인했습니다.
2. OrbStack 2.2.1은 running/stopped 양쪽에서 record ID 삭제가 nil-pointer panic으로 실패합니다. 제품의 이름 삭제
   fallback은 다른 머신 오삭제 가능성 때문에 금지했습니다.
3. OrbStack 자동 설치, Apple Developer 서명/notarization, 전용 비관리자 계정, cold boot, 계정/시크릿 연결은
   후속 acceptance 범위입니다.

따라서 이번 PR 병합은 위 기능을 완성했다고 선언하는 일이 아니라, 검증된 프로토타입 기반과 재현 가능한 blocker를
main에 보존하는 일입니다.

## 사전 검증

- Phase 1 독립 계획 검증: `refuted=false`
- Phase 2 core 독립 적대검증: `refuted=false`
- Phase 3 package/isolation/secret 독립 적대검증: `refuted=false`
- Phase 4 live evidence 재검증: `refuted=false`, blocker 0 / high 0 / medium 0
- Phase 4 staged manifest 5개 일치, untracked 0, `git diff --cached --check` PASS
- Cockpit `--integrity`: PASS; Phase 4가 blocked이므로 terminal 검사는 의도대로 미통과
- 최종 source-tree gitleaks 8.18.4: match 0
- 완료 화면: 화면 식별자 0, PNG metadata chunk 0
- Mac self-test UTC `2026-08-10T16:15:46Z~16:15:53Z`: 19 passed, 0 failed
- Mac 최종 상태 UTC `2026-08-10T16:10:11Z`: K-AI 두 머신과 보호 머신 모두 running, app process 0,
  임시 diagnostics 없음

## PR 게이트

- 공개 저장소: `spacewalk-labs/k-ai-installer`
- base: `main`
- head: `feat/macmini03-installer-spike-20260810`
- GitHub Actions 결과와 PR URL은 PR 생성 뒤 본문과 GitHub 기록을 정본으로 사용합니다.
- merge는 Actions 성공과 mergeability 확인 뒤에만 수행합니다.
