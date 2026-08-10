# Phase 1 — Mac mini 03 실측·실행 계약 검증

검증일: 2026-08-10 KST

## 읽기 전용 실측

- host: `swk-macmini-03`
- hardware: Mac14,3 / Apple M2 / arm64 / 8GiB
- macOS: 15.1.1 (24B91)
- Data volume: 약 195GiB 여유
- FileVault: Off
- GUI: `swk` 로그인·자동 로그인, admin
- OrbStack app: 2.2.1, Running
- existing machine: `kaipro-oneshot-mac1` 한 대. 이번 태스크의 금지 대상
- build tools: Swift 6.0.3, pkgbuild/productbuild/codesign
- OrbStack app: Gatekeeper accepted, Notarized Developer ID, bundle `dev.kdrag0n.MacVirt`, Team ID `HUAQ24HBR6`

실측은 `viewer` 및 Tailscale check가 유효한 `root` 세션에서 read-only 명령만 사용했습니다. 시크릿 값, 환경변수,
키 내용, 사용자 파일 내용은 수집하지 않았습니다.

실행한 probe 종류와 명령은 다음과 같습니다. 출력은 아래 allowlist 사실만 로그에 남겼습니다.

```text
sw_vers -productName|-productVersion|-buildVersion
uname -m
sysctl -n hw.model|hw.memsize
df -h /System/Volumes/Data
fdesetup status
stat -f %Su /dev/console
defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser
plutil -extract CFBundleShortVersionString|CFBundleIdentifier raw /Applications/OrbStack.app/Contents/Info.plist
spctl -a -vv /Applications/OrbStack.app
codesign -dv --verbose=4 /Applications/OrbStack.app
sudo -u swk -H /Applications/OrbStack.app/Contents/MacOS/bin/orb version|status|list|create --help|info --help
```

OrbStack machine 이름 전후 대조:

| 시점 | 전체 이름 | 이번 태스크 target 이름 |
|---|---|---|
| 계획 리뷰 전 | `kaipro-oneshot-mac1` | 없음 |
| phase 1 커밋 게이트 직전 | `kaipro-oneshot-mac1` | 없음 |

두 번째 대조 명령은 다음이며 output은 `status=Running`, protected 이름 1개, target 이름 0개였습니다.

```text
orb status
orb list | awk '{print $1}'
orb list | awk '{print $1}' | grep -E '^k-ai-(dev|runner)$'
```

## OrbStack 2.2.1 계약 대조

실제 `orb create --help`에서 다음을 확인했습니다.

- `ubuntu:noble` / arm64
- `--isolated`
- `--isolate-network`
- `--memory`, `--cpus`, `--disk`
- `--user-data`

실제 `orb info --format json`은 name, record ID, distro/version/arch, isolation config, state를 구조화 출력합니다.
GUI shell PATH에는 `orb`가 없을 수 있으므로 앱 내부 절대경로의 서명·bundle·Team ID·version을 검증해 사용합니다.

공식 대조 문서:

- https://docs.orbstack.dev/machines/
- https://docs.orbstack.dev/machines/isolated
- https://docs.orbstack.dev/machines/commands
- https://docs.orbstack.dev/licensing

## 독립 적대 리뷰

첫 리뷰는 `refuted=true`였습니다. 다음 결함을 반영했습니다.

- final runtime 계정과 이번 admin-user core spike의 경계를 분명히 함
- Finder PATH 의존 제거, OrbStack 서명·절대경로 검증 추가
- 이름만 믿는 rollback을 record ID + install ID + owner nonce 3자 대조로 강화
- manual `orb delete` 비상 절차 제거
- live host/sibling/file/SSH-agent positive control이 있는 isolation 검증 추가
- deterministic failpoint, atomic journal, corrupt-state fail-closed 추가
- 실제 Finder button action receipt를 create producer로 고정
- source/dist/runtime/support bundle secret scan과 synthetic positive/negative control 추가
- Verification 순서를 create → inspect → secret scan → owned cleanup으로 교정
- staged/untracked expected-file manifest 검증 추가

수정본 재리뷰 결과:

```text
Blocker/High는 남아 있지 않습니다.
refuted=false
```

## Phase 1 판정

- task cockpit integrity: PASS, 5 phases
- plan adversarial review: `refuted=false`
- 실제 OrbStack target write: 전후 target 이름 0개
- phase 2 진입 조건: Tailscale write check가 유효한 동안 Mac-side test/build만 수행
