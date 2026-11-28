# 32번 RBD/KRBD v2k·n2k 18대 이관 검증

2026-11-28 KST. [이슈 #93](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/93), [도구 PR #94](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/pull/94), [Mold PR #2011](https://github.com/ablecloud-team/ablestack-cloud/pull/2011).

**VMware 9대와 Nutanix 9대 모두 실제 wizard 이관·Mold 등록·실행·자동 복원 검증을 통과했다.** 각각 다른 호스트에서 중지/기동한 뒤 다시 `VERIFIED`를 확인했으며, 최종 18대는 Running이다. 대상 게스트의 NIC·IP·DATA online·드라이브 문자를 수동 보정한 횟수는 0이다.

[기계 판독 증거](issue93-rbd-migration-cluster32-20261128.json)에 원본/대상 UUID, 36개 볼륨, 이미지 식별자, 계획·helper 해시, 두 부팅 회차의 관측과 파일 검증을 기록했다. [구현 설계](../design/issue93-rbd-migration.md)는 KRBD 경로와 인계 이후 재개 경계를 설명한다.

## 실기 매트릭스

| 원본/운영체제 | 컨트롤러 | 펌웨어 | 대상 VM | 호스트 변경 | 캐시 | 결과 |
|---|---|---|---|---|---|---|
| Nutanix / Rocky 9.9 | IDE | EFI | `n2k-i93-rocky-ide-20261128` | 2 → 3 | none | Running / VERIFIED |
| Nutanix / Rocky 9.9 | SATA | EFI | `n2k-i93-rocky-sata-20261128` | 2 → 3 | none | Running / VERIFIED |
| Nutanix / Rocky 9.9 | SCSI | EFI | `n2k-i93-rocky-scsi-20261128` | 3 → 1 | writeback | Running / VERIFIED |
| Nutanix / Ubuntu 24.04 | IDE | EFI | `n2k-i93-ubuntu-ide-r2-20261128` | 2 → 3 | none | Running / VERIFIED |
| Nutanix / Ubuntu 24.04 | SATA | EFI | `n2k-i93-ubuntu-sata-20261128` | 1 → 2 | none | Running / VERIFIED |
| Nutanix / Ubuntu 24.04 | SCSI | EFI | `n2k-i93-ubuntu-scsi-20261128` | 2 → 3 | none | Running / VERIFIED |
| Nutanix / Windows 2022 | IDE | EFI | `n2k-i93-win2022-ide-20261128` | 1 → 2 | none | Running / VERIFIED |
| Nutanix / Windows 2022 | SATA | EFI | `n2k-i93-win2022-sata-20261128` | 2 → 3 | none | Running / VERIFIED |
| Nutanix / Windows 2022 | SCSI | EFI | `n2k-i93-win2022-scsi-20261128` | 2 → 3 | none | Running / VERIFIED |
| VMware / Rocky 9.7 | IDE | BIOS | `v2k-i93-rocky-ide-20261128` | 2 → 3 | none | Running / VERIFIED |
| VMware / Rocky 9.7 | SATA | EFI | `v2k-i93-rocky-sata-20261128` | 1 → 2 | none | Running / VERIFIED |
| VMware / Rocky 9.7 | SCSI | EFI | `v2k-i93-rocky-scsi-20261128` | 3 → 1 | writeback | Running / VERIFIED |
| VMware / Ubuntu 22.04 | IDE | BIOS | `v2k-i93-ubuntu-ide-r2-20261128` | 3 → 1 | none | Running / VERIFIED |
| VMware / Ubuntu 22.04 | SATA | EFI | `v2k-i93-ubuntu-sata-20261128` | 2 → 3 | none | Running / VERIFIED |
| VMware / Ubuntu 22.04 | SCSI | EFI | `v2k-i93-ubuntu-scsi-20261128` | 2 → 3 | none | Running / VERIFIED |
| VMware / Windows 2022 | IDE | BIOS | `v2k-i93-win2022-ide-20261128` | 2 → 3 | none | Running / VERIFIED |
| VMware / Windows 2022 | SATA | EFI | `v2k-i93-win2022-sata-20261128` | 3 → 1 | none | Running / VERIFIED |
| VMware / Windows 2022 | SCSI | EFI | `v2k-i93-win2022-scsi-20261128` | 2 → 3 | none | Running / VERIFIED |

원본 IDE/SATA의 auto 대상은 SATA/AHCI, 원본 SCSI의 auto 대상은 VirtIO-SCSI다. VMware IDE 3대의 BIOS와 나머지 15대의 UEFI를 유지했다. Windows Server 2022는 build 20348, Ubuntu는 VMware 22.04/Nutanix 24.04, Rocky는 9.7이다.

## 저장 정책과 자동 복원

- 실행 XML의 디스크 36개가 **KRBD block/raw**다. 실제 장치와 sysfs, Ceph의 pool/image ID를 인계 전 기록과 대조했다. 다른 호스트의 새 장치 번호에서도 같은 이미지임을 확인했다.
- none 정책 VM 16대/볼륨 32개, 명시적 writeback VM 2대/볼륨 4개를 확인했다. writeback은 양쪽의 Rocky SCSI 사례다. 실기 명령에는 캐시 값을 명시했고, 기본 none과 대화형 메뉴 선택은 자동 CLI/wizard 시험으로 검증했다.
- RBD preallocation은 `not_applicable`이다. Ceph 물리 예약이나 파일형 falloc 보장을 주장하지 않는다.
- Linux는 원본 MAC·인터페이스 이름과 netplan/NetworkManager 의도를 복원했다. Rocky SELinux Enforcing과 기존 QGA 제한도 유지했다.
- Nutanix Windows는 원본 정적 IPv4 **10.10.21.71~73/16**, gateway `10.10.0.1`, DNS `8.8.8.8`, `8.8.4.4`의 순서를 독립 관측했다. VMware Windows의 원본 DHCP 정책도 유지했다. DATA는 원래 online/RW와 문자를 유지했다(VMware E:, Nutanix T:).

## 파일과 재기동 검증

꺼진 원본을 읽기 전용으로 열어 UUID·파일시스템 식별자와 기준 파일 해시를 새로 확보했다. VMware는 VDDK의 읽기 전용 source NBD를 private appliance에 연결했고, Nutanix는 작업 전용 읽기 전용 NFS와 appliance를 사용했다. 이 source 읽기는 Mold 대상의 KRBD 접근과 구분되며 managed RBD를 오프라인으로 다시 열지 않았다.

대상에서는 원본 SHA-256 **360개를 두 회차, 총 720회** 대조했다. ROOT/DATA **36개 파일시스템**마다 65,536바이트 텍스트 파일을 배타적으로 생성해 fsync·읽기·해시를 확인했다. 다른 호스트에서 재기동한 뒤 같은 파일의 바이트와 해시가 남아 있는지 확인하고, 해당 시험 파일만 제거했다. 전체 이미지 해시 비교를 의미하지 않는다. 원본 VMware Rocky DATA 3개는 비어 있었으므로 원본 DATA 파일 해시 대신 파일시스템 UUID와 쓰기·재기동 후 읽기를 확인했다.

독립 관측은 VM UUID, 고정 helper/계획 해시와 현재 binding의 boot scope를 확인했다. Linux는 OS boot UUID, Windows는 시간 동기화와 별개인 OS BootId 카운터로 실제 재기동을 확인했다. helper의 기존 startup token은 그대로 유지했다.

동일 작업 디렉터리의 wizard를 재실행해 18대 모두 Mold 관측만 갱신했다. 원본 전송의 metrics/transfer와 controller/guest 계획이 바뀌지 않았음을 비교했다. RPM 설치 후에도 같은 18개 sealed 작업을 재검증해 모두 통과했다.

## 발견한 오류와 보완

| 관측 | 반영한 보완 |
|---|---|
| RBD preserve가 file/qcow2 gate에서 거부됨 | 소유권·image ID를 확인하는 KRBD/raw appliance adapter 추가 |
| KRBD 실행 XML이 network/rbd 검증에 맞지 않음 | Mold가 실제 block 매핑·pool/image·커널 image ID를 대조하고 관측을 반환 |
| 원래 run ID 필드와 소유권 기록 필드 불일치 | 실제 `run.run_id` 사용, 실제 manifest 형태의 회귀 시험 추가 |
| 준비 단계의 런타임 인수 누락 | API 인증 해석 함수의 인수를 명시하고 실제 shell stage 시험 추가 |
| 기동 전 응답에 실행 장치 관측을 요구함 | 기동 전 binding과 실행 후 KRBD image ID 검증의 시점을 구분 |
| n2k가 고정 CPU 속도 오퍼링에 override를 전송함 | 오퍼링 메타데이터를 읽어 고정 속도에는 override를 생략 |
| 부분 인계 재개에서 managed 볼륨을 미등록 이미지로 조회함 | 기록한 volume/job으로 재개하고 중복 import를 방지 |
| VMware BIOS/Q35에 IDE CD-ROM이 생성되어 기동 실패 | 기존 upstream CD-ROM 수정을 호환되는 메서드·필수 타입 범위로 적용 |
| Rocky의 기존 호스트 NBD/LVM 부팅 준비가 실패함 | RBD Linux는 KRBD appliance 안에서 dracut/update-initramfs와 AHCI/VirtIO/LVM 모듈을 준비·검증 |
| 구형 kmod의 builtin 출력 및 모듈 별칭 차이 | 실제 modinfo 파일명과 builtin 표식을 사용해 부팅 이미지 검증 |
| 구형 WinRM 클라이언트가 OpenSSL 3에서 실패함 | 고정 wheel SHA를 검사하는 전용 n2k Python 환경 제공·설치 |
| 실제 start/API 실패가 경고 성공 코드로 바뀜 | VM·볼륨을 유지하면서 원래 오류 코드를 전달, 의도적 define-only와 구분 |
| 새 ShellCheck가 EXIT trap 콜백을 미사용으로 판단함 | 실제 trap 호출을 설명하는 함수 한정 진단 주석 추가 |

71~73번은 처음에는 13번의 이전 Windows 검증 VM으로 연결됐다. UUID/MAC를 확인한 뒤 해당 이전 대상 3대를 중지해 보존하고 원본의 Duplicate 주소 상태를 해소했다. 이는 이관 전 원본 환경 정리이며 대상 게스트의 사후 수동 보정이 아니다. 준비 단계에서 정지한 15대도 보존했다.

## 빌드·배포 범위

기능 코드 `3a2ab0fb2202e4e679b3e9e3583fa8cd1c2c5614`에서 만든 v2k/n2k `0.10.0-1.issue93.el9.el9` RPM을 32번 호스트 3대에 정상 의존성 검사 후 설치했다. 호스트마다 RPM의 v2k 프로그램 68개와 n2k 프로그램 55개 digest를 대조했다. 공식 WinPE v0.9.5와 전용 원본 수집 환경의 보존도 확인했다. 마지막 ShellCheck 주석과 보고서 변경은 기능 동작을 바꾸지 않는다.

| 패키지 | SHA-256 |
|---|---|
| v2k x86_64 | `f67625d79226a7dd68420a18fb5bc5d81960a797aab66d1cd9510f18aa4a6ae3` |
| n2k noarch | `34844089dd3e973c6d900272eea1c42e2578e3294f685dc954f17947e96f5eb9` |

Mold 기능 변경은 KVM guard의 KRBD 검증이다. 관리 서버 전체 jar나 DB 스키마를 교체하지 않았다. 테스트 환경의 기존 BIOS/Q35 CD-ROM 수정 누락은 기존 런타임에서 필요한 메서드와 타입만 보완했다. 관련 없는 compute 메서드 448개가 유지되는지 확인하고 BIOS/UEFI·기존 i440fx·ARM/S390x/system VM·config drive 관련 자격 시험 4개를 통과했다.

## 자동 시험과 CI

- 관련 로컬 자동 시험 21개 묶음 통과. file/preallocation·실제 cutover/retention·sealed resume·RBD staging·기존 DR 소비자를 포함한다.
- 추가 RBD 안전성 11개와 Linux 부팅 드라이버 4개, Mold guard 11개 통과. 일부는 위 자동 시험 묶음에 포함된다.
- n2k 전체 ShellCheck, 변경 Java 파일의 Checkstyle 및 적용 가능한 pre-commit hook 통과.
- 도구 PR의 Ubuntu/Rocky 계약, Windows 정책, validate, lint/build, RPM build, compat installer CI 통과. 실행 링크는 JSON에 기록했다.
- Cloud 전체 CI는 기존 저장소의 RAT 미승인 파일 4,075개와 기존 코드/증거 자료의 서식·철자 오류로 실패한다. 이번 변경 Java 파일의 빌드·11개 단위 시험·변경 파일 검사 및 실기는 통과했다. 관련 없는 기존 자료를 이 PR에서 일괄 수정하거나 검사를 해제하지 않았다.

## 보존과 최종 상태

기존 Mold VM **60대의 UUID·이름·상태·호스트가 바뀌지 않았고**, 최종 사용자 VM 수는 78대다. 원본 18대는 최종 cutover 이후 꺼진 상태로 보존했다. Ceph는 HEALTH_OK, RBD 이미지는 124개에서 162개가 됐다(정상 이관 이미지 36개와 초기 실패의 미등록 이미지 2개 포함).

초기 소유권 기록 실패 때 publish된 `v2k-i93-ubuntu-ide-20261128-disk0`, `n2k-i93-ubuntu-ide-20261128-disk0`은 미등록 상태로 보존했다. 실패 VM/볼륨을 지우는 자동 경로는 추가하지 않았다. 실제 실패 후의 같은 작업 재개와 별도의 오류 주입 시험에서 `RETAINED_UNVERIFIED`, 원래 종료 코드와 리소스 식별자 보존을 확인했다.

인증은 런타임 입력과 보호된 운영 설정으로만 전달했다. 보고서·계획·소스에는 비밀번호나 API 인증 정보를 포함하지 않는다.
