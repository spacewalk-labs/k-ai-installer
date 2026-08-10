# Phase 3 verification

- 장비: `acceptance-mac`(공개용 역할명, GUI 사용자 컨텍스트)
- 검증 완료 시각: 2026-08-10T15:34:37Z 이전
- core source commit: `k-ai-installer@a3029b6`
- packaging commit: `k-ai-installer@905543a`
- Mac build toolchain: Swift 6.0.3, macOS 15.1.1 Command Line Tools
- app binary SHA-256: `0a04af6cc1da98fe03ed162ff46f2e3c7b041a3d39b0540c7901b740867ef785`
- app Info.plist SHA-256: `8aa4c1a11f07dde68bba67fa1f107d67496eec7847d9a101c9b63cf8c6567dbb`
- CLI SHA-256: `d1d665bfcacd14c6c049c6a2a4d791142c379317fd3d3571e385c52aab3f3481`

## 패키지

- `scripts/build-macos-app.sh`: PASS
- `dist/K-AI 설치.app`: 생성 확인
- `dist/kai-installer-cli`: 생성 확인
- `plutil -lint`: OK
- `codesign --verify --deep --strict`: PASS
- `kai-installer-cli probe --json`: Apple Silicon·arm64·macOS 15.x·preflight 통과·충분한 디스크와
  notarized OrbStack 2.2.1을 구조화 출력

이 산출물은 내부 프로토타입이라 ad-hoc 서명입니다. Apple Developer 배포 서명·notarization·외부 다운로드는 하지
않았으며, Mac mini 03에 이미 설치된 OrbStack만 확인해 사용합니다.

## fixture와 정적 검사

- `bash -n scripts/*.sh`: PASS
- `shellcheck scripts/*.sh`: PASS
- `xmllint --noout Resources/Info.plist`: PASS
- `dist` symlink negative fixture: repo 밖 경로를 변경하기 전에 명시적으로 거부, 외부 fixture 내용 0
- isolation fixture의 allowlist·양성대조·정확한 PID/path cleanup 계약: 독립 리뷰 `refuted=false`
- cleanup receipt의 PID가 비어도 소유자 marker와 guest PID file을 확인해 정리하는 fallback 포함
- OrbStack에는 atomic no-start guest 실행이 없어, 격리 fixture는 동시 VM 상태 변경이 없는 acceptance 전용입니다.
- GitHub Actions macOS job: checkout v4 commit 고정 → Swift major 6·toolchain 출력 → self-test → app build →
  checksum 검증한 gitleaks 8.18.4 순서

## 비밀 누출

`scripts/verify-secrets.sh`는 pinned gitleaks 8.18.4와 확장 규칙으로 synthetic BWS access token, GitHub PAT,
Tailscale auth key, private key 네 종류를 각각 탐지하고 safe control은 통과했습니다. 이어서 tracked
`phase3-secret-scan-targets.txt`와 실제 생성 manifest의 7개 label을 대조하고 source tree, `.app` plist/resources,
앱 binary strings, Mac mini 03의 실제 state·action receipt·redacted support diagnostics를 검사해 match 0을
확인했습니다. 실제 runtime 파일과 scan manifest는 mode 0600이며 원문·경로·식별자는 이 로그에 넣지 않았습니다.
