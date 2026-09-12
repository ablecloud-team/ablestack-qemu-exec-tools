# #1007 / #972: scheduler 재시작 의도와 Resume 기준점 보존

## 기준 및 범위
Cloud efc2799265 / qemu 03a16af에서 codex/fix-1007-972-scheduler-resume 생성. 통합 PR #1022/qemu #56 head를 보존하고 검증 완료 후 fast-forward로 반영한다. upstream 충돌 해결은 별도 통합 단계이며 이 작업에서 이전 변경을 재작성하지 않는다.

## 코드 설계
- dr_scheduler.sh worker 시작은 기존 control generation/command를 보존한다. control 파일 최초 생성만 plan lock 안에서 초기화한다. PAUSE/STOP와 시작이 경합해도 최신 명령을 덮지 않는다. 최초 ACK 및 status도 PAUSED/STOPPED/RUNNING 의도에 맞춘다.
- dr_runtime.sh의 pause/resume Run 생성은 Plan의 마지막 durable checkpoint 증거를 Run ID/terminal/authority와 분리해 승계한다. 완료 checkpoint ref 존재와 JSON의 plan/state/targetDurableAt 및 sequence를 검증하고 기존 latest_completed 메타데이터와 source disk map을 보존한다. 불완전하거나 다른 Plan의 증거는 승계하지 않는다.
- provider의 실제 RBD snapshot/qcow2 bitmap/CBT 유효성 검증은 유지한다. 과거 번호만 복사하여 delta를 강제하지 않는다. baseline 유실은 기존 명시적 재시드 정책을 따른다.
- 명시적인 Resume만 RUNNING 명령을 발행한다. restart는 STOP/RELEASE/target authority를 해제하지 않는다. VMware 양단 QGA 제외와 target-only disaster failover를 유지한다.

## 검증
PAUSED worker restart, STOPPED restart, RUNNING restart, 최초 시작 및 동시 제어 명령 회귀. 실제 pause→worker 소실→UI Resume에서 RBD/qcow2 checkpoint와 전송 mode를 검증한다. VMware pause/restart/resume 및 기존 테스트/정리 동작을 회귀 확인한다. lifecycle/release tombstone gate 실행. qemu shell 직접 배포하며 Cloud production 변경이 필요한 경우에만 WSL ext4 변경 Maven 모듈 빌드/배포한다. 실제 호스트 reboot와 process restart는 구분해 기록한다.
