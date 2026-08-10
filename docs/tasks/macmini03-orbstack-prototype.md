# TASK: Mac mini 03에서 K-AI 더블클릭 설치기 핵심 검증

<!-- cockpit:start -->
| phase | status | blocked_on | commit | verify_log |
|---|---|---|---|---|
| 1 실측·실행 계약 | done | - | k-ai-installer@0b4991f | `docs/tasks/macmini03-orbstack-prototype.logs/phase1-plan-review.md` |
| 2 네이티브 앱·공통 코어 | done | - | k-ai-installer@a3029b6 | `docs/tasks/macmini03-orbstack-prototype.logs/phase2-verification.md` |
| 3 패키지·격리 fixture | running | - | | |
| 4 Mac mini 03 실기 | pending | 3 + Tailscale 쓰기 승인 | | |
| 5 적대 검증·PR·머지 | pending | 4 | | |

| 항목 | 값 |
|---|---|
| `pr_url` | |
| `gate_log` | |
| `merged_sha` | |
<!-- cockpit:end -->

> 장비: `swk-macmini-03` · 실기 변경: **있음(가역)** · 공개 배포: **없음** ·
> 기준일: 2026-08-10 · 상위 계획: `k-ai-pro/docs/tasks/active/oneshot-installer.md`

## Outcome

Mac mini 03의 GUI 사용자 `swk`가 터미널을 열지 않고 `K-AI 설치.app`을 실행하면 앱이 현재 상태를 쉬운 말로
보여 주고, 추가 클릭 없이 다음을 수행합니다.

1. Apple Silicon·지원 macOS·디스크·FileVault·OrbStack 상태를 실제 값으로 확인합니다.
2. 앱이 소유한 새 이름일 때만 Ubuntu 24.04 계열 isolated machine `k-ai-dev`와 `k-ai-runner`를 생성합니다.
3. 두 머신 모두 Mac 파일·Mac 호스트·SSH agent·다른 OrbStack 머신 네트워크를 차단하고 인터넷은 유지합니다.
4. 각 머신 안에 K-AI 소유 표식을 기록하고, Mac의 비시크릿 실행원장으로 중단 뒤 재개합니다.
5. 두 번째 실행은 기존 머신을 재생성하거나 삭제하지 않고 검증만 통과합니다.
6. 실패 시 사용자는 앱에서 원인을 보고 다시 시도할 수 있으며, 지원자는 redacted 진단 파일을 받을 수 있습니다.

이번 PR의 Mac mini 03 core/create 완료 조건은 앱 실행, 최초 생성, 두 번째 멱등 실행, 앱 재실행, 두 K-AI
Ubuntu 머신 재시작 뒤 검증과 격리 확인입니다. 소유권 확인이 붙은 복구는 반드시 record ID 삭제로만 수행해야 하며,
OrbStack 2.2.1의 ID 삭제 panic이 해결된 버전에서 별도 acceptance를 통과하기 전까지 release blocker입니다.

Cockpit phase 5의 `done`은 **core/create feasibility 완료**만 뜻합니다. 전용 비관리자 runtime 계정,
OrbStack 사용자별 가시성·자동시작, macOS cold boot를 통과한 후속 PR 없이는 Mac 설치기를 release-ready로
표시하거나 공개 다운로드하지 않습니다.

## 이번 범위에서 하지 않는 것

- Mac 포맷, macOS 재설치, 현재 `swk` 계정·자동 로그인·전원·원격 로그인·Tailscale 설정 변경
- OrbStack 전체 stop/start, macOS cold boot. 기존 `kaipro-oneshot-mac1`을 중단할 수 있어 이번 실기에서 제외
- OrbStack 전체 reset 또는 이름이 같은 기존 머신의 자동 삭제·변경
- Apple Developer 서명·notarization·외부 사용자를 위한 Gatekeeper 배포
- OrbStack이 없는 Mac의 자동 다운로드·설치. 이번 실기는 설치된 2.2.1을 사용하고, 부재 시 쉬운 차단 화면만 만듦
- OrbStack 상용 라이선스 구매·조직 계정 가입의 대리 수행. 회사 사용자는 유효 라이선스가 필요하며 앱은 이를 안내
- Claude·GitHub App/runner·Bitwarden·Tailscale guest 연결과 실제 K-AI 업무도구 설치
- M710q·Windows USB·Ubuntu Desktop 경로
- 조직 저장소 runner와 회사 시크릿

위 제외 항목은 핵심 VM 생성기가 실기 통과한 뒤 별도 태스크로 진행합니다. 특히 “OrbStack까지 자동 설치”와
“계정 연결 한 화면”은 최종 제품에 필요하지만, 이번 태스크에 섞으면 실패 원인이 앱·가상화·계정 중 어디인지
구분할 수 없으므로 경계를 둡니다.

이번 태스크의 통과는 **최종 Mac 설치 경로 통과가 아닙니다.** 후속 Mac acceptance는 전용 비관리자 runtime
계정에서 로그인·자동시작·화면 잠금·재부팅 뒤 자동 복구를 별도로 검증해야 합니다. 현재 admin `swk` 세션에서의
결과를 그 검증의 대체 증거로 사용하지 않습니다.

## 확인된 장비 사실

2026-08-10 `viewer@swk-macmini-03` 읽기 전용 실측값입니다.

| 항목 | 값 | 이번 태스크의 의미 |
|---|---|---|
| 모델 | Mac14,3 / Apple M2 / arm64 / 8GiB | 지원 대상 |
| macOS | 15.1.1 (24B91) | Swift 6·macOS 15 SDK 사용 가능 |
| 디스크 | Data 228GiB 중 약 195GiB 여유 | 머신 2대 생성 가능 |
| FileVault | Off | 헤드리스 재부팅 잠금 없음 |
| GUI | `swk` 로그인·자동 로그인, `swk`는 admin | 기존 세션에서 OrbStack 실기 가능 |
| OrbStack | 2.2.1, `/Applications/OrbStack.app` | 재설치 대신 상태·CLI 연결 검증 |
| 빌드 도구 | Swift 6.0.3, `pkgbuild`, `productbuild`, `codesign` | Mac에서 실제 `.app` 제작 가능 |
| 원격 관리 | viewer/ubuntu/root + Tailscale | 읽기는 개방, 쓰기는 check 승인 뒤 수행 |

OrbStack 공식 계약은 [Linux machines](https://docs.orbstack.dev/machines/),
[Isolated machines](https://docs.orbstack.dev/machines/isolated),
[Commands](https://docs.orbstack.dev/machines/commands),
[Licensing](https://docs.orbstack.dev/licensing)를 기준으로 합니다. 회사 사용은 사용자별 라이선스가 필요합니다.
isolated machine은 `--isolated`로
Mac 파일·호스트·SSH agent를 차단하고, `--isolate-network`로 다른 머신과 host IP를 추가 차단하면서 인터넷은
유지합니다.

## 가장 단순한 구현

### 제품 표면

- SwiftUI 앱 1개: `K-AI 설치.app`
- 첫 화면은 전문 용어 대신 `이 Mac 확인 → Ubuntu 작업공간 2개 만들기 → 확인 완료` 세 줄만 표시
- 앱을 열면 즉시 시작하고, 버튼은 실패 뒤 `다시 시도`에만 사용합니다. 완료 뒤에는 `준비 완료`를 표시합니다.
- 터미널 명령과 step ID는 앱에 노출하지 않음

### 내부

- Swift Package 1개에 Foundation 기반 core, SwiftUI app, 검증용 CLI를 둡니다.
- core는 shell 문자열을 실행하지 않고 `Process.executableURL + arguments`로 `sw_vers`, `fdesetup`, `orb`를 호출합니다.
- step은 `probe → plan → apply → verify` 네 상태만 갖습니다. 별도 daemon, root helper, localhost API는 만들지 않습니다.
- GUI 앱의 `PATH`는 믿지 않습니다. 우선 `/Applications/OrbStack.app/Contents/MacOS/bin/orb`, 그다음 현재
  사용자의 `~/.orbstack/bin/orb`만 후보로 삼고, `spctl` notarization, bundle identifier
  `dev.kdrag0n.MacVirt`, Team ID `HUAQ24HBR6`, `orb version` 호환성을 확인한 바이너리만 실행합니다.
- 실행원장은 `~/Library/Application Support/KAI Installer/state.json`에 version, install ID, 머신 이름,
  OrbStack machine record ID, 256-bit owner nonce의 SHA-256, 마지막 검증 결과만 기록합니다.
  token·환경변수·명령 전체 stdout은 기록하지 않습니다. state와 임시 cloud-init은 mode 0600입니다.
- 실행원장은 같은 디렉터리의 임시 파일에 encode·sync한 뒤 rename하는 atomic write만 사용합니다. 손상되거나
  schema가 미래/미지원 버전이면 새 설치로 간주하지 않고 fail-closed 합니다.
- 머신 소유권은 고정 allowlist 이름, Mac 원장의 install ID·machine record ID·owner nonce hash,
  guest `/etc/k-ai-installer/owner.json`의 install ID와 owner nonce를 모두 대조할 때만 인정합니다. plaintext nonce는
  create용 mode 0600 cloud-init 임시 파일과 guest의 root-only 영역에만 존재하고 create 직후 host에서 지웁니다.
  cloud-init cache를 포함한 guest 내 사본은 일반 사용자에게 읽히지 않는지 확인하고 support bundle에서 제외합니다.
- `orb create --isolated --isolate-network --memory 2G --cpus 2 --disk 24G ubuntu:noble <name>`을 기본으로 하되,
  Mac mini 03의 실제 `orb create --help`로 이 계약을 확인했습니다.
- 완료 판정은 `orb info --format json <name>`의 `isolated=true`, `isolate_network=true`,
  `forward_ssh_agent=false`, `ubuntu/noble/arm64`를 독립적으로 확인합니다.
- `k-ai-dev`와 `k-ai-runner`에는 이번 단계에서 mount를 하나도 주지 않습니다. dev의 선택 폴더 mount는 후속 UI
  태스크에서 사용자가 고른 폴더만 추가합니다.

8GiB 장비에서 두 guest의 상한을 각각 2GiB로 두고, idle 상태 실제 메모리를 검증합니다. 동시에 무거운 작업을
돌리는 acceptance는 이번 범위가 아닙니다.

## 안전 경계와 실패 처리

1. 동명 머신이 이미 있는데 소유 표식을 증명하지 못하면 **즉시 중단**하고 삭제·config 변경을 하지 않습니다.
2. app은 `orb reset`, wildcard 삭제, 다른 머신의 config 변경을 호출하지 않습니다.
3. create가 중간 실패하면 생성된 이름과 guest 표식을 다시 검사하고, 앱 소유가 증명된 단계만 이어갑니다.
   create 전에 pending journal을 atomic write하고, record가 생겼지만 owner marker가 없거나 nonce가 다르면 자동
   adopt/delete하지 않고 fail-closed 합니다. marker가 pending install ID·nonce와 일치할 때만 record ID를 원장에
   보강해 재개합니다.
4. rollback도 install ID, machine record ID, 고정된 두 이름을 모두 대조한 뒤 사용자 확인을 받아야 실행합니다.
5. 진단은 allowlist 필드만 저장하며 홈 경로, 사용자 환경, SSH key, token, 전체 process list는 수집하지 않습니다.
6. 이번 실기의 Mac 쓰기는 Tailscale check 승인 뒤 `root`가 GUI 사용자 `swk` 컨텍스트로 제한 실행합니다.
7. 실제 장비 명령은 repository revision을 기록하고, 실행 전후 머신 목록을 증거 로그에 남깁니다.

## 단계와 PR 경계

| # | 산출물 | 종료 조건 | 비가역 | 무커밋 |
|---|---|---|---|---|
| 1 | 이 태스크, 장비 실측, OrbStack CLI 계약 | 독립 리뷰에서 `refuted=false` | 아니요 | 아니요 |
| 2 | core, CLI, SwiftUI 앱, unit test | fake orb로 create/재개/충돌/rollback 계약 통과 | 아니요 | 아니요 |
| 3 | `.app` build, fixture, redaction 검사 | Mac 빌드·앱 구조·secret scan 통과 | 아니요 | 아니요 |
| 4 | Mac mini 03 실기 증거 | 최초/멱등/재시작/격리 검증 통과, rollback blocker 실측 | 실 머신 변경(가역) | 아니요 |
| 5 | 적대 검증, PR, squash merge | self-verify 통과·PR merged | 공개 repo merge | 아니요 |

한 PR로 묶되 Cockpit의 각 phase 종료 때 코드와 로그를 커밋합니다. 실기 로그는 시크릿과 식별자를 제거한 뒤
`docs/tasks/macmini03-orbstack-prototype.logs/`에 저장합니다.

## Verification

| # | 검사 | 명령/관측 | 성공 조건 |
|---|---|---|---|
| V1 | 작업 범위 | 모든 산출물을 stage한 뒤 `git diff --cached --check`; `git diff --cached --name-only \| sort \| diff -u docs/tasks/macmini03-orbstack-prototype.logs/phase<N>-expected-files.txt -`; `git status --porcelain=v1` 대조 | phase별 manifest와 정확히 일치, untracked·unexpected 파일 0, whitespace 오류 0 |
| V2 | Swift self-test | `scripts/run-self-tests.sh` (Mac mini 03) | 전체 Xcode/XCTest 추가 설치 없이 create/owned resume/unowned collision/partial retry/rollback/redaction 전부 PASS |
| V3 | 앱 build | `scripts/build-macos-app.sh` (Mac mini 03) | `dist/K-AI 설치.app` 생성, exit 0 |
| V4 | 앱 구조 | `plutil -lint 'dist/K-AI 설치.app/Contents/Info.plist'` 및 `codesign --verify --deep --strict ...` | plist OK, ad-hoc signature valid |
| V5 | CLI 계약 | `dist/kai-installer-cli probe --json` | 지원 모델·OS·disk·FileVault·OrbStack을 구조화 출력하고, notarized OrbStack Team ID·bundle ID·version 확인, secret 0 |
| V6 | Finder UI·생성 | GUI 사용자에서 Finder/open으로 `.app` 실행하고 window를 독립 관측 → 추가 옵션 없이 앱 시작; `app-launch` action receipt의 process PID·app build SHA 기록 | CLI apply 회차는 불인정; 이 receipt 하나가 V7~V9의 유일한 실기 create producer |
| V7 | 새 머신 상태 | V6 receipt 뒤 record ID로 `orb info --format json`, `orb config get`의 CPU·memory·disk, guest owner 확인; cloud-init 완료 60초 뒤 guest cgroup memory.current 3회 측정 | 두 이름만 추가; noble/arm64, 2CPU·2GiB·24GiB, 격리 config, owner 일치; 각 guest 3회 모두 512MiB 이하 |
| V8 | isolation | host와 sibling guest에 live canary를 띄워 host/자기 자신에서 먼저 200 positive control 확인; host disposable `ssh-agent`에 ephemeral key를 넣어 `ssh-add -L` 성공 확인; 이후 대상 guest에서 `/mnt/mac`와 `/Users/swk`의 random sentinel 부재, `SSH_AUTH_SOCK` 부재·ephemeral key 접근 실패, host/sibling canary 접근 실패, HTTPS public probe 성공 확인 | canary·agent positive control 성공, 파일·agent·host·sibling 차단 + 인터넷 성공 |
| V9 | 멱등·재개 | fake orb failpoint를 create 전, child 실행 중, record 생성 후 owner marker 전, dev owner 확인 후 runner 전, 최종 verify 전에 각각 주입하고 재실행; 손상·truncate state도 주입; 실기는 V6 앱 두 번째 실행과 두 owned machine을 record ID로 각각 restart한 뒤 재실행 | 소유가 증명된 단계만 재개하고 중복 create/delete 0; 무표식 record는 보존한 채 지원 필요로 중단; corrupt state fail-closed; 최종 verify 성공 |
| V10 | 충돌 안전 | fake orb 동명·무표식 fixture | exit nonzero, delete/config 호출 0 |
| V11 | 비밀 누출 | gitleaks가 synthetic `BWS_ACCESS_TOKEN`·GitHub·Tailscale·private-key fixture는 거부하고 safe fixture는 허용; tracked/untracked expected source, `.app` plist/resources와 binary `strings`, 실제 state.json, support bundle을 별도 manifest로 스캔 | positive/negative control 통과, 문서·test allowlist 외 실제 대상 match 0 |
| V12 | rollback·cleanup | V6 receipt와 Mac state, guest owner nonce hash, record ID를 검증한 CLI로 rollback 실행 | OrbStack이 record ID 삭제를 정상 지원할 때만 소유 두 머신·정확한 state file 제거. Mac mini 03의 OrbStack 2.2.1은 ID 삭제 내부 panic으로 현재 BLOCKED; 이름 삭제 fallback 금지 |
| V13 | Cockpit | `python3 /home/josh/workspace/swk-wiki/swk-wiki-vault/40_Playbooks/_System/task-to-done/scripts/verify-cockpit.py docs/tasks/macmini03-orbstack-prototype.md` | terminal PASS |
| V14 | 독립 적대검증 | `/self-verify-seven` 결과 | `refuted=false` |

V6~V10의 실기에는 정확한 명령, UTC 시각, app build SHA, 전후 머신 이름만 기록합니다. IP·사용자 홈·token은
증거에서 제거합니다. GUI 버튼 동작은 화면 녹화 대신 앱 journal과 `orb` 독립 관측을 함께 사용합니다.

## Rollback

이번 내부 프로토타입의 실기 rollback은 지원용 CLI로만 수행합니다. CLI는
**owner.json, machine record ID, Mac 원장이 모두 일치하지 않으면 중단**하며, 삭제 인자에도 record ID만 사용합니다.
OrbStack 2.2.1은 이 ID 삭제에서 내부 panic을 내므로 현재 CLI는 아무 머신도 지우지 못하고 안전하게 실패합니다.
이름 삭제 fallback과 일반 사용자용 제거 버튼은 사용하지 않습니다. OrbStack 수정 버전을 확인한 후 별도 태스크에서
record ID 삭제 acceptance와 사용자 확인 UI를 추가합니다.

```bash
# GUI 사용자 swk 컨텍스트에서 실행. 아래 두 이름 외에는 허용하지 않는다.
kai-installer-cli rollback --require-owner --machine k-ai-dev --machine k-ai-runner
```

검증된 CLI가 없거나 3자 대조가 실패하면 수동 `orb delete`로 우회하지 않고 중단·지원 요청합니다.
`/Applications/OrbStack.app`, 다른 OrbStack 머신, Mac 계정·설정은 어떤 rollback에서도 삭제하지 않습니다.

## 중단 조건

- OrbStack 2.2.1의 실제 CLI가 공식 `--isolated --isolate-network` 계약을 제공하지 않음
- 동명 머신의 사전 존재 또는 소유권이 불명확함
- isolation 검증에서 Mac 파일·host·SSH agent·다른 guest 접근 중 하나라도 성공함
- Mac Data 여유 공간이 80GiB 아래로 내려감
- build/test artifact에서 credential 패턴이 검출됨
- root Tailscale check 승인 없이 실기 쓰기가 필요함

중단은 실패를 숨기는 수동 우회로 바꾸지 않습니다. 원인을 증거에 남기고 해당 phase를 `blocked`로 표시합니다.
