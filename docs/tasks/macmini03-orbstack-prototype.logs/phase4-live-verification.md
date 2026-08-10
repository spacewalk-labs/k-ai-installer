# Phase 4 — Mac mini 03 live verification

- 장비: `acceptance-mac`(공개용 역할명) / Apple Silicon / 8GiB / arm64
- OS: macOS 15.x, 보안 preflight 통과(실제 값은 비공개 증거)
- GUI 사용자: `<gui-user>`(공개용 역할명)
- OrbStack: notarized 2.2.1
- 실행 기간: 2026-08-10T14:00Z~16:10Z
- 보호 대상: 기존 `<pre-existing-control-vm>`(공개용 역할명)
- 판정: **BLOCKED — core/create feasibility는 확인했지만 V6 최종 후보 clean-create와 V12 안전 삭제가 미충족**

운영 호스트명·계정·원격 접근 방식·보안 설정값, IP, install ID, machine record ID, nonce와 사용자 홈의 실제
내용은 기록하지 않았습니다. 정확한 내부 명령은 비공개 증거에 두고, 아래 공개 사본에서는 운영 식별자를
`<gui-user>`, `<gui-uid>`, `<pre-existing-control-vm>` 역할명으로 치환했습니다.

```bash
run_user() {
  sudo -u <gui-user> env HOME=/Users/<gui-user> USER=<gui-user> LOGNAME=<gui-user> LC_ALL=C LANG=C "$@"
}
```

## 증거 한계 — V6는 PASS가 아님

새 머신이 없을 때 GUI 사용자 컨텍스트에서 다음 명령으로 앱을 열어 `k-ai-dev`, `k-ai-runner`가 생성되는 것과 완료
화면을 관측했습니다.

```bash
launchctl asuser <gui-uid> sudo -u <gui-user> \
  env HOME=/Users/<gui-user> USER=<gui-user> LOGNAME=<gui-user> LC_ALL=C LANG=C \
  /usr/bin/open -F -n '/Users/Shared/k-ai-installer-build-20260810/dist/K-AI 설치.app'
```

- 실행 전 이름: `<pre-existing-control-vm>`
- 실행 후 이름: `k-ai-dev,k-ai-runner,<pre-existing-control-vm>`
- clean-create producer SHA-256: `1c9d648f918da9c7ef5e2b9ed2ac27a484d75f1e1c02eb66be7fc2cbd117d689`
- 완료 화면: `ui-complete.png`

그러나 이 영수증은 이후 최종 후보를 반복 실행하면서 덮어썼고, OrbStack record에도 생성 시각이 없습니다. 따라서 최초
clean-create의 개별 UTC 시각을 사후 복구할 수 없습니다. 이후 transaction lock, record-ID-only rollback, deletion
journal, pending recovery diagnostics를 추가한 최종 후보 SHA-256은
`0a04af6cc1da98fe03ed162ff46f2e3c7b041a3d39b0540c7901b740867ef785`입니다. 최종 후보는 실제 legacy schema 1
state를 읽고 멱등 실행·verify·재시작·격리 검사를 통과했지만, 깨끗한 상태에서 새로 만든 producer는 아닙니다.

그러므로 V6의 “하나의 최종 app-launch receipt가 V7~V9 create producer” 계약은 미충족이며, 이 결과를
release-ready 근거로 사용하지 않습니다. 완료 화면 PNG는 화면 무식별 확인 뒤 ICC/text metadata도 제거했습니다.

## 시각·명령 장부

### 최종 앱 무인 재실행과 멱등성 — PASS

- UTC: 시작 `2026-08-10T16:01:36Z`, receipt `2026-08-10T16:01:37Z`, 종료 `2026-08-10T16:01:49Z`
- 실행 전/후 이름: 각각 `k-ai-dev,k-ai-runner,<pre-existing-control-vm>`
- 정확한 실행 명령:

```bash
launchctl asuser <gui-uid> sudo -u <gui-user> \
  env HOME=/Users/<gui-user> USER=<gui-user> LOGNAME=<gui-user> LC_ALL=C LANG=C \
  /usr/bin/open -F -n '/Users/Shared/k-ai-installer-build-20260810/dist/K-AI 설치.app'
sleep 8
run_user '/Users/Shared/k-ai-installer-build-20260810/dist/kai-installer-cli' verify
```

`app-launch`, 실제 실행 중 PID, receipt/app binary SHA 일치, CLI `verified=true`, 머신 2대, 전후 record ID 불변을
값을 출력하지 않고 대조했습니다. create/delete는 0이었고 receipt PID만 종료했습니다.

### 머신 계약과 소유권 — PASS

- UTC: `orb info` 시작 `2026-08-10T16:05:33Z`, 독립 CLI owner verify 종료 `2026-08-10T16:05:53Z`
- 정확한 명령:

```bash
run_user "$ORB" info --format json k-ai-dev
run_user "$ORB" info --format json k-ai-runner
run_user '/Users/Shared/k-ai-installer-build-20260810/dist/kai-installer-cli' verify
```

| 항목 | `k-ai-dev` | `k-ai-runner` |
|---|---:|---:|
| state | running | running |
| image/arch | ubuntu:noble / arm64 | ubuntu:noble / arm64 |
| CPU | 2 | 2 |
| memory limit | 2048MiB | 2048MiB |
| disk limit | 24GiB | 24GiB |
| isolated | true | true |
| network isolated | true | true |
| SSH agent forwarding | false | false |
| Mac state·record·guest owner 3자 대조 | PASS | PASS |

### record ID 재시작 — PASS

- UTC: 전체 `2026-08-10T16:02:16Z~16:02:21Z`; dev `16:02:17Z`; runner `16:02:17Z`
- 실행 전/후 이름: 각각 `k-ai-dev,k-ai-runner,<pre-existing-control-vm>`
- 보호 머신: 실행 전/후 모두 running
- 정확한 명령 구조:

```bash
# RID는 mode 0600 state.json의 해당 이름 recordID를 읽고, orb info 결과 이름과 먼저 대조했습니다.
run_user "$ORB" info --format json "$RID"
run_user "$ORB" restart "$RID"
run_user "$ORB" info --format json "$RID"
run_user '/Users/Shared/k-ai-installer-build-20260810/dist/kai-installer-cli' verify
```

두 record ID는 전후 동일했고, 이름·running 상태·owner/contract verify가 모두 통과했습니다.

### 재시작 뒤 isolation — PASS

- 본 검사 UTC: `2026-08-10T16:03:27Z`
- 검사 전 이름: `k-ai-dev,k-ai-runner,<pre-existing-control-vm>`; 보호 머신 running
- 종료 뒤 cleanup/상태 독립 확인 UTC: `2026-08-10T16:04:03Z`
- 정확한 명령:

```bash
cd /Users/Shared
run_user '/Users/Shared/k-ai-installer-build-20260810/scripts/verify-orbstack-isolation.sh' \
  --orb-path '/Applications/OrbStack.app/Contents/MacOS/bin/orb' \
  --dev k-ai-dev --runner k-ai-runner
```

- host/sibling HTTP canary와 disposable ssh-agent positive control: PASS
- Mac 파일·sentinel·SSH_AUTH_SOCK·ephemeral key 접근 차단: PASS
- Mac host와 sibling guest canary 접근 차단: PASS
- public HTTPS: 두 guest 모두 PASS
- host와 두 guest 임시 canary cleanup: PASS
- 종료 뒤 이름: `k-ai-dev,k-ai-runner,<pre-existing-control-vm>`; 세 머신 모두 running

검사는 다른 actor가 VM 상태를 바꾸지 않는 통제된 구간에서 수행했습니다. OrbStack에는 atomic no-start guest 실행이
없으므로 동시 stop과의 TOCTOU는 이 acceptance의 전제 밖입니다.

### 유휴 메모리 — PASS

- UTC: 시작 `2026-08-10T16:04:19Z`
- 정확한 명령: 각 머신에서 아래 명령을 1초 간격으로 3회 실행

```bash
run_user "$ORB" -m "$NAME" cat /sys/fs/cgroup/memory.current
```

- dev: 73MiB, 76MiB, 75MiB
- runner: 61MiB, 61MiB, 61MiB
- 여섯 측정 모두 512MiB 미만: PASS

### 실제 runtime 포함 시크릿 검사 — PASS

- diagnostics 생성 UTC: `2026-08-10T16:06:46Z`
- scan UTC: `2026-08-10T16:06:53Z~16:06:54Z`
- pinned gitleaks: 8.18.4
- 정확한 명령:

```bash
run_user "$CLI" diagnostics --output '/Users/Shared/k-ai-diagnostics-current.json'
scripts/verify-secrets.sh \
  --runtime-state "$SCAN_DIR/state.json" \
  --runtime-receipt "$SCAN_DIR/ui-action.json" \
  --runtime-diagnostics "$SCAN_DIR/support-diagnostics.json" \
  --manifest-output "$SCAN_DIR/scan-manifest.txt"
```

검사 대상 label은 `source-tree,app-binary-strings,app-info-plist,app-resources,runtime-state,runtime-receipt,`
`runtime-diagnostics`의 정확히 7개였습니다. BWS·GitHub·Tailscale·private-key 네 positive control은 각각
탐지됐고 safe control은 허용됐으며 실제 match는 0이었습니다. state, receipt, diagnostics, manifest는 mode
0600이었습니다. 원격 진단과 로컬 runtime 사본은 검사 직후 제거했습니다.

### OrbStack record ID 삭제 — BLOCKED

- UTC: `2026-08-10T16:08:46Z~16:09:20Z`
- 실행 전/후 이름: 각각 `k-ai-dev,k-ai-runner,<pre-existing-control-vm>`
- 정확한 핵심 명령:

```bash
run_user "$ORB" create --isolated --isolate-network --memory 1G --cpus 1 --disk 8G \
  ubuntu:noble "$RANDOM_DISPOSABLE_NAME"
run_user "$ORB" info --format json "$RANDOM_DISPOSABLE_NAME"  # record ID와 이름 대조
run_user "$ORB" delete --force "$RID"                         # running: panic, nonzero
run_user "$ORB" stop "$RID"
run_user "$ORB" delete --force "$RID"                         # stopped: panic, nonzero
run_user "$ORB" delete --force "$RANDOM_DISPOSABLE_NAME"      # 시험 VM만 정리
```

OrbStack 2.2.1은 running/stopped 양쪽 모두 `delete --force <record ID>`에서 nil-pointer panic으로 실패했습니다.
시험 VM은 직전에 생성한 무작위 이름과 ID를 다시 대조한 뒤 이름으로만 정리했습니다. 최종 제품 코드는 동시 교체
TOCTOU 때문에 이름 fallback을 하지 않습니다. V12는 PASS가 아니라 release blocker입니다.

### 최종 장비 스냅샷

- UTC: `2026-08-10T16:10:11Z`
- 정확한 명령: `orb list -q`, 세 이름 각각 `orb info --format json`, app process·진단 파일 존재 검사
- `k-ai-dev`: running
- `k-ai-runner`: running
- `<pre-existing-control-vm>`: running
- 테스트 앱 프로세스: 0
- 임시 support diagnostics와 canary: 없음
- 내부 build artifact: `/Users/Shared/k-ai-installer-build-20260810/dist/K-AI 설치.app`

## 재검증 중 성공 근거에서 제외한 시도

- `16:00:18Z`: app receipt 직후 CLI verify를 겹쳐 실행해 `transactionBusy`가 발생했습니다. 잠금의 정상 동작이지만
  멱등 성공 근거로 쓰지 않고 `16:01:36Z` 실행을 다시 측정했습니다.
- `16:02:39Z`: 운영자 전용 SSH 현재 디렉터리에서 isolation script를 불러 host canary startup이 실패했습니다.
  임시물 cleanup 뒤 GUI 사용자가 접근 가능한 `/Users/Shared`에서 다시 실행했습니다.
- `16:08:22Z`: disposable VM에 OrbStack 최소치보다 작은 512MiB를 요청해 생성 전에 거부됐습니다. 생성된 VM은
  없었고, 1GiB로 다시 실행한 결과만 위 삭제 계약 근거로 사용했습니다.

## 최종 판정

최종 후보의 기존 owned 머신 검증, 무인 재실행, 멱등성, record-ID 재시작, 격리, 메모리, 시크릿 검사는
통과했습니다. 그러나 최종 후보 자체의 clean-create V6 receipt가 없고 OrbStack 2.2.1의 record-ID 삭제가
깨져 있으므로 Phase 4는 `blocked`입니다. 전용 acceptance 장비 또는 안전 삭제를 지원하는 OrbStack 버전에서
clean create → idempotence → restart → isolation → rollback/crash-recovery를 하나의 최종 SHA로 다시 수행해야 합니다.
