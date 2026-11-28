# RBD 이관의 KRBD 자동 복원 설계와 구현

관련: [이슈 #93](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/93), [도구 PR #94](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/pull/94), [Mold PR #2011](https://github.com/ablecloud-team/ablestack-cloud/pull/2011).

준비 단계 이후 운영자의 구현 승인을 반영한 최종 설계다. 32번 Mold의 디스크 접근 방식인 **KRBD**를 변환·게스트 준비·최종 실행에 적용한다. 준비 당시 환경과 원본 목록은 [준비 보고서](../validation/issue93-rbd-cluster32-20261128.md)에 남긴다.

## 정책

| 항목 | 적용 정책 |
|---|---|
| 저장 형식 | RBD/raw, preallocation은 `not_applicable` |
| 접근 방식 | Mold 신규 작업은 KRBD 기본값. preserve 준비는 KRBD만 허용 |
| 캐시 | 신규 기본값 `none`, 명시적 `writeback` 지원, 기존 sealed 값 보존 |
| 컨트롤러 auto | IDE·SATA → SATA/AHCI, SCSI → VirtIO-SCSI |
| 펌웨어 | 원본 BIOS/UEFI 유지 |
| 게스트 | Ubuntu 22.04/24.04, Rocky 9.7, Windows Server 2022 build 20348의 기존 자격과 고정 helper 계약 사용 |

CLI와 wizard는 같은 정책·계획을 사용한다. 기존 file/qcow2의 falloc 정책과 libvirt 대상의 접근 방식 선택은 유지한다. RBD에 파일형 falloc을 적용하거나 Ceph 물리 예약을 보장한다고 표시하지 않는다.

## 복사와 소유권

원본 UUID·디스크 주소·역할·크기 및 목적지 URI를 확정한 다음 작업 전용 staging 이미지를 만든다. KRBD 장치에 raw 데이터를 복사하고 flush·unmap을 완료한 뒤 기존 목적지를 덮어쓰지 않는 publish를 수행한다. 부분 복사·publish 실패는 기존 사용자 이미지를 변경하지 않는다.

preserve 작업은 publish 직후 `rbd info`의 image ID·크기와 run/source VM/source disk/URI를 `ablecloud.migration.owner.v1` 메타데이터 및 manifest에 기록한다. 게스트 준비에서는 이 기록과 현재 이미지를 다시 대조한다. 이름만 같은 이미지, 소유권 기록이 없는 이미지, 중복 URI, snapshot/namespace/옵션이 들어간 URI와 지원하지 않는 크기는 거부한다.

## Mold 인계 전 준비

1. Mold `listVolumesForImport`로 모든 목적지가 해당 primary storage의 미등록 이미지인지 확인한다.
2. worker 파일 잠금, Ceph watcher와 기존 매핑 확인을 거쳐 새 커널 매핑만 만든다. 장치의 종류·크기·읽기 전용 값·sysfs image ID를 확인한다.
3. 고정된 private libguestfs appliance에 raw 블록 장치를 전달한다. 게스트 파일시스템과 LVM은 appliance 안에서 처리한다.
4. Linux의 MAC/인터페이스 이름과 netplan·NetworkManager 설정, Windows의 DATA online/RW/문자 및 정적 IPv4·gateway·DNS 의도를 기존 guest plan으로 준비한다. QGA와 helper 자산은 기존 해시 검증을 거친다.
5. RBD Linux는 같은 appliance에서 AHCI·VirtIO·SCSI·device-mapper/LVM 부팅 모듈을 준비한다. dracut 또는 update-initramfs 실행 후 각 커널의 실제 모듈·builtin 여부와 이미지 해시를 확인한다. 호스트 LVM 활성화 경로를 사용하지 않는다.
6. WinPE가 필요한 Windows 경로는 생성한 KRBD 매핑을 별도 기록한다. 임시 VM이 중지된 뒤 같은 image ID의 자기 매핑만 flush·unmap한다. 실행 중 VM과 외부 매핑은 해제하지 않는다.
7. 준비 결과와 helper/계획 해시를 확인하고 자기 매핑을 해제한 다음 Mold에 ROOT·DATA를 인계한다.

NTFS용 appliance, OS별 QGA 패키지, VirtIO/WinPE 자산은 worker의 보호된 운영 자산을 사용한다. 코드와 별도로 자격 및 SHA-256을 확인한다. n2k Windows 수집의 전용 Python 환경은 [설치 절차](../n2k/source-runtime.md)를 따른다. 인증 문자열은 계획·자산·로그에 저장하지 않는다.

## 인계 후 검증과 재개

ROOT import job, VM 배포 job 또는 ROOT/VM/DATA 식별자가 기록되면 인계가 시작된 상태로 간주한다. 이후에는 managed 이미지를 오프라인으로 열거나 원본을 다시 복사하거나 고정 helper/계획을 교체하지 않는다. 재개는 기존 작업의 UUID와 job을 대조하며 중복 import·VM 생성을 방지한다.

Mold/Agent는 첫 기동 전 controller/firmware/volume binding을 검증한다. 실행 후에는 XML의 블록 장치를 실제 KRBD 매핑으로 해석하여 pool/image, 커널 sysfs 및 Ceph image ID를 대조한다. 도구는 이 관측을 인계 전에 기록한 image ID와 비교한다. 준비 단계 장치 번호는 영구 권한으로 사용하지 않는다. 다른 호스트에서도 새 장치 번호를 같은 이미지로 긍정 확인해야 한다.

기존 guest v1/v2의 plan/helper/binding/report와 현재 boot scope 검증을 유지한다. Windows static/DHCP 의도, Linux 네트워크, ROOT/DATA 및 캐시 확인이 완료되어야 검증 완료로 표시한다. 기존 RBD 계획에 새 접근 방식 필드를 소급 추가하여 hash를 변경하지 않는다.

## 실패 보존

실패·시간 초과는 `RETAINED_UNVERIFIED`로 기록하며 Mold VM·볼륨의 현재 상태와 재개 정보를 보존한다. 실제 start/API/guest 검증 오류의 원래 종료 코드를 전달한다. 의도적으로 선택한 define-only/off는 실행 성공 코드와 별개로 검증 미완료임을 표시한다. 지원 불가를 자동 off나 성공으로 바꾸지 않는다.

미등록 이미지의 실패 재개는 동일 작업의 소유권을 재확인한다. 인계 이후의 재개는 Mold 관측을 갱신한다. 정상적인 중지·다른 호스트 시작·Agent 재시작 뒤에도 helper와 operation/plan은 고정하고 boot scope를 새로 확인한다.

## 검증 기준

- VMware/Nutanix 원본 각 9대의 실제 wizard, ROOT+DATA 반입, 실행 및 자동 복원 `VERIFIED`.
- 실제 XML의 KRBD/raw, pool/image ID, controller, firmware 및 cachemode 대조. 기본 none 16대와 명시적 writeback 2대를 구분한다.
- 꺼진 원본을 읽기 전용으로 열어 파일 SHA와 파일시스템 식별자를 확보하고 대상에서 독립 대조한다.
- ROOT/DATA마다 소유한 64 KiB 텍스트 파일을 fsync·읽기 확인한다. 다른 호스트에서 재기동한 뒤 같은 파일의 해시와 새 boot scope를 확인하고 해당 시험 파일만 제거한다.
- 미지원 형식·권한/소유권·매핑 충돌·부분 복사·인계 실패·stale/timeout·재개 및 기존 file/libvirt/DR 소비자를 자동 시험한다.

실기 결과, 초기 실패와 보완, 배포한 코드·자산의 범위는 별도 검증 보고서에 기록한다. 과거 GFS2 결과를 RBD 검증 결과로 대신하지 않는다.
