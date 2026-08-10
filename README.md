# K-AI 쉬운 설치

새 Mac mini에서 터미널 명령 없이 K-AI용 Ubuntu 작업공간을 준비하는 설치기입니다.

현재 단계는 Mac mini 03 실기용 내부 프로토타입입니다. Apple 공증과 일반 배포는 아직 하지 않습니다.

## 사용자가 하는 일

1. `K-AI 설치.app`을 엽니다.
2. 기다립니다.
3. `준비 완료`가 나오면 끝입니다.

앱을 열면 설치가 자동으로 시작됩니다. 실패했을 때만 `다시 시도`를 누릅니다.

앱은 기존 OrbStack 머신을 지우지 않습니다. 앱이 직접 만든 `k-ai-dev`, `k-ai-runner` 두 Ubuntu만 관리합니다.
같은 이름이 이미 있거나 소유권을 확인할 수 없으면 변경하지 않고 멈춥니다.

이번 내부 프로토타입은 Mac mini 03에 이미 설치된 OrbStack을 확인해 사용합니다. OrbStack까지 자동 설치하는 기능은
다음 배포 단계에서 추가하며, 현재는 OrbStack이 없으면 쉬운 안내를 보여 주고 멈춥니다.

## 개발자용

macOS 14 이상과 Swift 6이 필요합니다.

```bash
scripts/run-self-tests.sh
scripts/build-macos-app.sh
```

산출물은 `dist/K-AI 설치.app`과 `dist/kai-installer-cli`입니다. 내부 프로토타입은 ad-hoc 서명만 사용합니다.

실행 계약과 실기 검증표는
[`docs/tasks/macmini03-orbstack-prototype.md`](docs/tasks/macmini03-orbstack-prototype.md)에 있습니다.
