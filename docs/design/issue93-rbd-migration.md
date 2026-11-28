# 32번 RBD 이관 준비와 게스트 자동 복원 확장 설계

관련: [이슈 #93](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/93).

이번 PR은 환경 준비와 설계 단계다. 운영자가 **환경 준비·RBD 개선 설계까지**로 범위를 지정했다.
RBD 자동 복원 코드를 구현하거나 VM 디스크 복사·Mold 반입·cutover를 실행하지 않는다.
환경과 원본 상태는 [준비 보고서](../validation/issue93-rbd-cluster32-20261128.md)에 기록한다.

## 유지할 계약

- 새 캐시 기본값 none, 명시적 writeback, 기존 sealed 작업의 캐시/driver/guest 계획을 유지한다.
- RBD 이미지는 raw다. 파일형 기본 falloc을 RBD에 전달하거나 Ceph 물리 예약으로 설명하지 않는다.
- IDE→SATA/AHCI, SATA→SATA/AHCI, SCSI→VirtIO-SCSI의 auto 정책과 원본 BIOS/UEFI를 유지한다.
- guest plan/helper/binding/report, ROOT/DATA UUID와 현재 boot scope를 검증한다. 실패 시 RETAINED_UNVERIFIED와 실패 종료 코드를 유지하며 대상과 현재 상태를 보존한다.
- handoff 이후 managed 이미지를 guestfs로 다시 열거나 helper/계획을 교체하지 않는다.

## 현재 제약

Mold의 RBD controller binding은 pool/image path, 볼륨 UUID 및 실행 XML의 network/rbd source를
대조하는 코드가 있고 32번의 현재 worker capability를 확인했다. 그러나 클라이언트의
`guest_configuration_prepare.py:preflight`는 file/qcow2만 허용한다. RBD/raw에 preserve를
요청하면 복사 전에 GUEST_CONFIG_TARGET_UNSUPPORTED로 거절한다.

이 gate를 없애거나 RBD에서 자동 off로 바꾸면 안 된다. Windows DATA·정적 IP/gateway/DNS와
Linux NIC 자동 복원의 GFS2 실기를 RBD 지원으로 소급 해석하지 않는다. 명시적 off baseline은
자동 복원과 별도 시험이며, 실행해도 guest 설정의 VERIFIED/완료를 주장하지 않는다.

## 후속 실행 단계

1. source inventory와 guest 의도를 읽고 ROOT를 확정한다. PC device UUID와 PE 실제 vDisk UUID,
   CD-ROM을 구분한다. 명확하지 않은 ROOT는 stable selector를 요구한다. 겹치는 MAC/IP의 소스와
   이전 대상이 동시에 네트워크에 연결되지 않도록 cutover 순서를 기록한다.
2. 현재 storage worker, raw/RBD data plane, controller/firmware, cache, guest adapter 및 필요한
   Windows/Linux payload를 각각 협상한다. CLI/wizard/yes/preview가 같은 결과를 보여야 한다.
   preview는 인증 문자열을 마스킹하고 snapshot·이미지·manifest·Cloud 자원을 만들지 않는다.
3. 소스를 작업 소유의 private RBD 이미지에 복사하고 복사 무결성을 확인한다. 마지막 원본 동기화와
   승인된 종료 뒤 guest 준비를 한다. hibernated/dirty NTFS를 임의 수리하지 않는다.
4. 새 RBD adapter에서 고정된 helper·driver·네트워크/DATA 계획을 적용한다. 아래 후보의 실제
   libguestfs/QEMU/Ceph 동작을 시험한 뒤 구현 경로를 확정한다.
5. 필요한 변경과 guest 준비 후검사를 완료한 다중 디스크 집합만 publish한다. 최종 pool/image와
   immutable RBD image identity, 형식·크기·ROOT/DATA 역할을 작업 manifest에 기록한다.
6. Mold ROOT/DATA 등록·controller 조립·첫 시작 전에 UUID, image identity, raw, cache와 guest
   binding을 확인한다. 시작 후 실제 guest의 현재 결과를 확인해야 완료한다. 같은 manifest의
   재개는 기존 이미지·VM·볼륨을 재사용하며 새 원본 snapshot/복사로 돌아가지 않는다.

## 오프라인 RBD adapter 후보

| 후보 | 절차 | 검증할 사항 |
|---|---|---|
| private RBD + NBD/block | 작업 전용 이미지를 qemu-nbd 등으로 제한적으로 노출하고 ROOT/DATA를 libguestfs에 전달 | 현행 도구에서 raw/NBD 조합, root inspection, NTFS appliance, SELinux, exclusive access, mapping 소유/해제·프로세스 중단 복구 |
| local staging 후 publish | 작업 전용 로컬 raw/qcow2에 준비한 뒤 RBD 이미지로 전달하고 publish | 두 표현의 정확한 변환·크기, 임시 파일·공간·복사 비교, 멀티디스크 부분 실패 및 원자적 완료 기록 |

현재 3개 worker에 qemu-nbd/guestfish/virt-customize가 있고 rbd-nbd는 없다. 존재만으로 adapter가
검증된 것은 아니다. RBD 접근 키는 기존 보호된 운영 설정을 사용하고 manifest·명령 미리보기·로그에
값을 넣지 않는다. 임시 device/worker 경로는 실행 관측/lease이며 영구 배치 권한으로 고정하지 않는다.

source raw byte 비교는 guest 준비 이전 복사 경계에서 한다. 준비 뒤에는 의도한 OS 변경을 journal로
구분하고 원본 사용자 파일의 SHA와 filesystem identity를 검증한다. OS 설정을 변경한 디스크 전체가
원본과 byte-identical하다고 주장하지 않는다.

## 공간·소유·실패와 인계

18대의 원본 가상 디스크 합계는 678 GiB, 최대 VM은 72 GiB다. RBD pool은 관측 시 replica size=2지만
thin allocation·공유 사용량·quota를 별도로 고려한다. 가상 용량 합계로 물리 공간을 예약했다고
표시하지 않는다. allocation의 file/falloc receipt를 RBD에 위조해 넘기지 않는다.

현재 worker 로컬 여유 공간은 약 111/192/234 GiB다. local staging 후보는 source staging, output,
overlay/rollback, appliance, 안전 여유를 합산해야 한다. 특히 32.1에서 최대 VM의 두 전체 표현을
동시에 보관하는 가정을 해서는 안 된다. 현재 자원 상태로 적격 worker를 선택하며 특정 host를
필수 바인딩하지 않는다.

임시 이름/namespace, operation UUID, RBD image ID, 작업 소유 receipt를 결합한다. 정리는 작업이
만든 미인계 자원에만 허용하고 기존 사용자 이미지를 truncate/remove하지 않는다. image별 rename이
다중 이미지 전체의 원자성을 보장한다고 가정하지 않는다. 모든 디스크가 준비됐다는 durable manifest
없이 Mold 인계를 시작하지 않는다. async 응답 유실 시에는 계정·pool/image identity와 operation을
대조해 기존 등록 결과를 재조회하거나 충돌로 차단하며 중복 import로 해결하지 않는다.

## 검증 계획과 완료 기준

- VMware/Nutanix 각각 Windows·Ubuntu·Rocky × IDE/SATA/SCSI 9대, 원본 BIOS/UEFI와 RAW/RBD를 검증한다.
- 기본 none/명시적 writeback, ROOT/DATA 순서·전체 인식, VM·볼륨 UUID, 최종 image path, API/XML 및
  실제 guest의 disk/firmware/network를 대조한다. Ceph client cache와 file preallocation을 혼동하지 않는다.
- Linux는 MAC/ifname·netplan/NetworkManager·주소/routes/DNS/MTU·DATA mount, Windows는 DATA online/RW·
  원래 문자와 정적 IPv4/prefix·gateway/metric·DNS 순서를 확인한다. 원본이 DHCP인 사례로 정적 IP 자격을 대신하지 않는다.
- 현재 boot scope, stale/unbound 보고서, 관리/Agent/worker 재시작, 부분 복사/import/attach/start,
  인증·공간·형식·identity 오류 및 재개를 검증한다. 실패를 성공으로 표시하지 않고 자원은 보존한다.
- 원본 사용자 파일 SHA·fsync/readback, 다른 호스트 stop/start 후 새 관측과 기존 GFS2/libvirt/RBD
  baseline 회귀를 수행한다. 공유 selector/Agent/배치 코드를 바꾸면 기존 DR 소비자 회귀 gate도 적용한다.

구현과 실제 이관은 후속 지시 후 같은 이슈/작업 PR에서 진행한다. 이번 준비 단계에서 #93을 닫지 않는다.
