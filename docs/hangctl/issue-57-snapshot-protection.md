# 메모리 VM 스냅샷 중 hangctl 강제 종료 방지 (#57)

## 적용 범위

메모리 스냅샷이 libvirt 작업 잠금을 점유하면 QMP와 domjobinfo 조회도 실패할 수 있다.
기존 코드는 빈 작업 응답을 None으로 취급하고 paused 300초 후 dump/destroy를 실행했다.
destroy timeout 뒤 TERM/KILL로 승격하여 스냅샷과 VM을 종료한 것이 #57의 직접 원인이다.

이번 변경은 hangctl 셸 코드만으로 이 경로를 차단하는 1차 수정이다.
Mold Agent의 작업 lease 및 공통 잠금 연동은 포함하지 않는다. 외부 도구가 최종 검사
직후 새 작업을 시작하는 경쟁을 원자적으로 제거하려면 해당 후속 연동이 필요하다.
이 PR 병합만으로 #57 전체 완료 또는 스냅샷 E2E 성공으로 간주하지 않는다.

## 판정과 조치

- 작업 조회 성공과 명시적인 `Job type: None`만 NONE이다. 오류, timeout,
  빈 응답, 인식 불가능한 응답, 도메인 상태 조회 실패는 UNKNOWN이다.
- `paused (saving/snapshot/restoring/dump/migration/in-migration/post-copy)`와
  active job은 ACTIVE로 보호한다. `running (from snapshot)`은 현재 작업이 아니다.
- ACTIVE/UNKNOWN이면 dump/destroy/TERM/KILL을 보류하고 로그를 남긴다.
  UNKNOWN이 일반 확인 시간을 넘거나 보호 시간이 migration 확인 시간을 넘으면
  `attention_required=1` 경고로 운영자 확인을 요청한다. 시간 초과만으로 종료하지 않는다.
- 이 정책은 오래 정체된 migration/backup에도 적용한다. 기존 migration 진행률
  분석 함수는 유지하지만 zombie/no-progress만으로 자동 kill하지 않는다.
  장시간 작업의 취소/복구는 해당 작업 소유자와 운영자가 판단해야 한다.
- 정상 QMP 응답과 running 상태의 유휴 VM은 I/O가 없더라도 정상이다.
- 최초 의심 시각을 마지막 heartbeat와 분리하고, 작업 보호 종료 및 정상 관측 시
  초기화한다. 이전 버전 상태 파일도 첫 새 관측부터 확인 시간을 계산한다.
- 조치 진입, dump, destroy, TERM, KILL 직전에 작업 상태, FTCTL 보호 및
  VM UUID/PID/프로세스 시작 시각을 다시 검사한다. PID는 libvirt pidfile과
  QEMU argv의 UUID로 검증하며 pgrep의 부분 이름 일치로 선택하지 않는다.
- destroy timeout(124/137/143)은 signal 승격 없이 종료한다.
- dry-run은 dump 및 스토리지 보정도 실행하지 않는다.
- 종료 확인 조회 실패를 stopped 성공으로 보고하지 않는다.

## 자동 검증

```bash
bash tests/hangctl_snapshot_protection_smoke.sh
for test in tests/hangctl_*smoke.sh; do bash "$test" || exit; done
```

신규 테스트는 실제 탐지/조치 함수를 사용하되 libvirt, dump, signal을 mock으로
치환한다. saving/snapshot 상태, 124/137/143 및 기타 오류, 빈/잘못된 job 응답,
정상 작업 종료 후 타이머, 이전 캐시, dry-run, FTCTL, PID 변경, 조치 단계 사이의
새 snapshot, 복구된 VM, destroy timeout과 실제 일반 paused hang 경로를 확인한다.
각 보호 사례에서 파괴적인 동작 호출이 0회인지 검증한다.
이는 실제 메모리 스냅샷 생성·복원 E2E를 대체하지 않는다.

## 운영자 스냅샷 테스트

1. 배포된 4개 셸 파일의 해시와 hangctl timer active/enabled를 확인한다.
   해당 VM의 실제 libvirt 상태가 running이며 UI의 호스트와 일치하는지 확인한다.
2. 테스트 시작 시각, VM UUID/이름, 현재 호스트와 PID를 기록한다.
3. UI에서 **메모리 포함 VM 스냅샷**을 생성한다. 이번 준비 작업은 이 단계를 실행하지 않는다.
4. 스냅샷 진행 중 해당 호스트 events.log에서 `vm.operation_guard`와
   `job_probe_state=ACTIVE` 또는 `UNKNOWN`을 확인한다. 작업이 300초보다 오래
   걸리더라도 해당 VM의 dump/destroy/TERM/KILL이 발생하지 않아야 한다.
5. 생성 성공 여부와 오류 원문/작업 ID, 종료 시각, VM 생존을 기록한다.
   성공 후 보호가 해제되고 정상 heartbeat로 복귀하는지 확인한다.
6. 스냅샷 복원은 운영자가 별도로 선택한 검증 시간에 수행한다.
   생성 성공만으로 복원/데이터 정합성까지 검증됐다고 판정하지 않는다.

호스트에서 조회할 로그 예시(읽기 전용):

```bash
VM=i-2-165-VM
grep -F "\"vm\":\"${VM}\"" /var/log/ablestack-vm-hangctl/events.log | tail -100
virsh domstate --reason "$VM"
virsh snapshot-list "$VM"
# 시간은 실제 테스트 구간으로 교체
journalctl -u libvirtd.service --since '2026-09-16 12:00:00' --no-pager
```

실패 시 관리/Agent/libvirtd/QEMU와 hangctl 로그를 같은 시간대 기준으로 대조한다.
인증 데이터와 메모리 덤프는 이슈/PR에 첨부하지 않는다.

## 셸 코드만 배포 및 롤백

반영 파일은 `bin/ablestack_vm_hangctl.sh`와
`lib/hangctl/{detect,actions,state_cache}.sh`다. 패키지/바이너리/설정은 변경하지 않는다.
배포 전 timer만 일시 중지하고 진행 중 oneshot이 끝나기를 기다린 뒤 기존 scan lock을
획득한다. 원본/권한/해시를 호스트별 백업 경로에 저장하고 검증된 4개 파일을 반영한다.
실패하면 원본을 복원한다. 이후 timer를 기존 상태로 돌리고 자연 실행되는 scan을
확인한다. Agent/libvirtd 또는 VM의 재시작은 필요 없다.

패키지 버전은 그대로이므로 운영 기록에는 소스 커밋 및 반영 파일 해시를 함께 남긴다.
패키지 무결성 검사의 해당 셸 파일 checksum 차이는 이번 hotfix의 예상 결과다.
롤백은 백업 원본을 같은 timer/lock 절차로 복원하는 방식이다. 원래 결함도 복원되므로
메모리 스냅샷 진행 중에는 롤백하지 않는다.
