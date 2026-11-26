# v2k/n2k 대상 이미지 preallocation

관련 설계: [upstream 이슈 #84](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/84).

## 사용자 옵션과 기본값

두 도구의 `init`, `run`/`auto`, `wizard`/`migrate`/`interactive`에서
`--target-preallocation <off|metadata|falloc|full>`을 지원한다.
n2k의 `plan`/`preflight`에도 같은 옵션을 지정할 수 있다.

| 최종 대상 | 새 작업의 기본값 | 지원하는 명시값 |
|---|---|---|
| 파일 qcow2 | `falloc` | `off`, `metadata`, `falloc`, `full` |
| 파일 raw | `falloc` | `off`, `falloc`, `full` |
| RBD / 기존 블록 장치 | 적용 안 함 | `off`만 허용하며 파일 생성 옵션은 전달하지 않음 |

`metadata`는 qcow2 메타데이터만 미리 할당한다. `falloc`은 파일시스템 공간을
확보하고, `full`은 공간을 할당하고 초기화한다. 미지원 조합·빈 값·알 수 없는
값은 오류이며 `falloc,cluster_size=...` 같은 범용 옵션 문자열은 받지 않는다.

아래 예시에서는 인증·VM 선택 등 기존 필수 인자를 생략했다.

```bash
ablestack_v2k run --target-storage file --target-format qcow2 --target-preallocation falloc ...
ablestack_n2k init --target-storage file --target-format raw --target-preallocation full ...
ablestack_v2k wizard --target-profile libvirt-qcow2 --target-preallocation metadata ...
ablestack_n2k wizard --target-profile cloud-filesystem --target-preallocation off ...
```

## Wizard

신규 파일 대상에서 옵션을 생략하고 대화형으로 진행하면 지원 모드 선택 화면이
표시된다. Enter는 `falloc`을 선택한다. raw 선택지에는 `metadata`가 없다.
명시값이 있으면 같은 항목을 다시 질문하지 않는다. `--yes`/`-y` 및
`--print-command`에서는 preallocation을 추가로 질문하지 않고 기본값을 결정한다.
명령 출력과 실제 실행은 같은 인자 배열을 사용하며 요약에 값과 출처를 표시한다.

Cloud 파일 저장소와 libvirt 파일 대상에 동일하게 적용한다. RBD/블록은
선택 화면을 표시하지 않는다. 취소·명령 출력은 manifest 정책이나 이미지를
변경하지 않는다. 기존 비밀값 마스킹과 최종 실행 확인은 유지한다.

## Manifest와 재개

선택값은 `target.storage.preallocation`, 출처는
`target.storage.preallocation_source`에 저장한다. 파일 대상에는 모드 문자열,
RBD/블록에는 `null`을 기록한다.

업그레이드 전 manifest에 필드가 없으면 파일 대상은 `off`로 해석한다.
phase2/재개 시 새 기본값을 소급하지 않는다. 대상이 아직 없고 생성 이력도
없을 때만 명시값을 변경할 수 있다. 생성이 시작되었거나 기존 파일/완료 상태가
있으면 정책 변경을 거부한다. 다른 정책으로 재시도하려면 새 workdir을 사용한다.

각 디스크의 `transfer.preallocation`에 모드·방식·생성 시작/완료·검증 상태와
할당량을 기록한다. 생성 실패나 부분 복사 파일을 자동으로 덮어쓰거나 삭제하지
않는다. 완료된 대상의 재개는 다시 생성하지 않는다. status/plan은 기존 필드를
유지하면서 정책 정보를 추가한다.

## 생성·복사 계약과 버전 호환성

- v2k의 nbdcopy 경로는 `qemu-img create -o preallocation=<mode>`로 생성한다.
  `falloc`/`full`에는 nbdcopy `--allocated`를 적용한다.
- 선할당 raw와 qcow2는 `qemu-nbd`로 내보내어 nbdcopy가 로컬 파일을 truncate할
  수 없게 한다. 이는 Rocky 9의 libnbd 1.20처럼 `--no-truncate`가 없는 버전에서도
  사용할 수 있다. 이슈 설계의 직접 파일 `--no-truncate` 대신 같은 보존 계약을
  NBD 대상에서 구현한 것이다. `--allocated`가 없으면 convert 방식 선택을
  안내하고 종료한다. `off`로 자동 변경하지 않는다.
- v2k convert 및 n2k 파일 변환은 `-o preallocation=<mode>`를 전달한다.
  `falloc`/`full`에서는 `-S 0`으로 복사 중 sparse 처리가 할당을 해제하지 않게 한다.
  파일 생성 convert에는 `-n`을 혼용하지 않는다.
- n2k raw `off`는 기존 sparse cp/dd 경로를 유지한다. RBD staging·재시도·publish와
  `-S` 정책, 블록 장치 기록 방식, Cloud writeback offering은 유지한다.
- QEMU raw의 `-o help`는 파일 프로토콜 이름이 있어야 protocol 수준의
  `preallocation`을 표시한다. 기능 확인은 `file:/dev/null`에 대한 도움말 조회만
  사용하며 probe 이미지를 생성하지 않는다.
- 할당 미지원·용량 부족·권한 오류는 실패로 기록한다. 생성/복사 후 포맷·가상 크기와
  `falloc`/`full`의 파일시스템 할당량을 검증한 뒤 base 완료를 기록한다.

각 독립 RPM/DEB가 자기 도구 디렉터리에 정책 helper를 포함한다. 공통 패키지나
상대 도구 설치를 요구하지 않으며 두 helper의 동일성 및 독립 설치 경로를 시험한다.

## 기본값 변경과 운영 영향

새 파일 대상은 과거의 sparse 기본 동작보다 더 많은 공간을 생성 시 확보한다.
`falloc`/`full`의 복사는 영(0) 영역의 기록량과 시간이 증가할 수 있다.
과거의 sparse 동작이 필요하면 **신규 작업에 `--target-preallocation off`를 명시**한다.

파일시스템 할당은 하부 thin LVM/Ceph/SAN의 물리 용량 예약을 보장하지 않는다.
게스트 discard 이후의 영구 예약 정책도 아니다. 실제 운영 파일시스템·quota의
지원 여부와 필요 공간은 해당 환경에서 확인한다.

## 검증

```bash
python3 tests/image_preallocation_test.py
shellcheck bin/ablestack_n2k.sh lib/n2k/*.sh
bash tests/v2k_base_transfer_retry_smoke.sh
bash tests/n2k_integrity_hardening_smoke.sh
```

전용 Actions는 Ubuntu/Rocky 9에서 정책·CLI·wizard·legacy 재개·설치 경로,
v2k nbdcopy/convert 및 n2k convert의 파일 모드 21개 조합을 시험한다.
원본의 영(0)/비영(0) 영역을 포함해 `qemu-img compare`와 실제 할당량을 확인한다.
ENOSPC/미지원/권한 실패는 주입 시험으로 no-fallback과 실패 상태 보존을 확인한다.
임시 이미지와 fixture만 사용하며 실제 vCenter/Nutanix/Cloud VM 마이그레이션이나
운영 파일시스템 검증은 수행하지 않는다.
