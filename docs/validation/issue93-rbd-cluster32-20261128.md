# 32번 RBD 이관 시험 준비 보고서

2026-11-28 KST. [이슈 #93](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/93)의
**환경 준비·RBD 개선 설계** 단계다. [상세 JSON](issue93-rbd-cluster32-20261128.json)과
[후속 설계](../design/issue93-rbd-migration.md)를 함께 기록한다.

## 준비 결과

| 항목 | 확인 결과 |
|---|---|
| 32번 KVM 3대 | Up/Enabled, mold-agent active |
| 도구 | 각 호스트 v2k 0.10.0-1.x86_64 / n2k 0.10.0-1.noarch, 프로그램 파일 검증·새 캐시 기본값 none 확인 |
| VMware SDK | esxi55/vsphere60/vsphere67/vsphere80 profile의 govc·Python/pyVmomi·VDDK 검증 |
| Ceph | HEALTH_OK, OSD 15/15 up+in, PG 1057 active+clean |
| RBD pool | rbd, replica size=2, 기존 image 124개 유지 |
| 원본 | VMware 9대 poweredOn 및 guestToolsRunning/guestOperationsReady, Nutanix 9대 ON, NIC 연결 확인 |
| 기존 32번 VM | 60개 UUID·이름·상태·호스트 변경 0건 |
| 미리보기 | v2k/n2k 각각 실제 cloud-rbd wizard preview 1회 성공, 새 manifest 생성 0 |
| 실제 이관 | 실행하지 않음. source snapshot·RBD 대상 이미지·Mold 대상 VM 생성 0 |

도구는 최신 병합 main `fa00e0d1a34c38e17a3230f35a9aef662e742e98`에서 빌드한 RPM을 사용했다.
호스트의 기존 v0.9.5를 `aspkg/aspm`으로 업그레이드하고 `/var/backups/rbd-cluster32-20261128`에
기존 도구를 보관했다. 저장소 설정을 변경하지 않고 서명 검증한 오프라인 의존 패키지를 설치했다.

v2k의 설치기가 생성하는 compat profile 파일에는 RPM placeholder와의 예상 차이가 있다.
이 영역을 제외한 프로그램 파일은 RPM과 일치하며 profile은 별도 검증했다. n2k RPM 검증은 차이 0이다.

## Mold 상태와 후속 실행 자원

- API 표시 버전: `4.23.0.0-Mold.Europa-202609222315`, 관리 패키지 `cloudstack-management-4.23.0.0-1`.
- 실행 관리 jar SHA-256: `94d2a25767baed14a21c18e2296058fb24ef80c4f3e67887918476cb9bd83ddf`.
- controller/guest policy·manager 핵심 4개 클래스의 SHA는 최신 병합 기준
  `49b70d9bd1aef98c91e23e56b5f8286a60318fa2`의 빌드 결과와 일치한다. 표시 버전의 날짜만으로
  코드를 오래됐다고 판정하지 않았으며, 전체 관리 jar의 모든 모듈이 같은 revision이라고도 주장하지 않는다.
- 각 호스트를 지정한 q35 BIOS/EFI controller capability와 guest v1/v2 capability, 총 12개 probe를
  확인했다. SATA/SCSI 및 Windows `windows-network-ipv4-v1`·build 20348 응답을 확인했다.
  이는 Agent 계약 지원이며 클라이언트의 RBD 오프라인 guest adapter 자격과 구분한다.
- 관리 서비스·UI·WEB-INF는 정상이다. 이번 단계에서 Cloud 패키지나 Agent jar를 교체/재시작하지 않았다.

| 자원 | 값 |
|---|---|
| API | http://10.10.32.10:8080/client/api |
| Zone | 991d2f57-0f37-4445-b956-09773d064816 |
| RBD primary | 91cae554-3fce-3f93-89d1-cefaf9bf8122 / rbd / CLUSTER / Up |
| 네트워크 | ADMIN-L2-Network, 78aabc42-0648-49c9-9d39-4cd6b212ebe8, vlan://untagged |
| compute offering | 1C1GB-TO-64C128GB-FR, 601d6b07-f649-4781-95a1-a522d3cd7125, customized·Active·tag 없음 |
| worker 선택 | 현재 적격 worker 자동 선택. 이번 capability probe의 host ID를 영구 배치 권한으로 사용하지 않음 |

32.1에서 vCenter 443, PC/PE 9440, PE NFS 2049 연결과 NFS export 목록을 확인했다.
default-container export에는 10.10.0.0/16 접근이 선언돼 있다. 다른 container까지 접근 가능하다고
일반화하지 않으며 실제 snapshot의 container/path·byte 읽기는 후속 실행에서 확인한다.
QEMU 10.1.0, nbdcopy/libnbd 1.20.3을 관측했다.

## 원본 18대

VMware는 운영자가 제공한 `V2K-Test-20261126` 폴더의 원본을 사용했다. #91 작업용 Windows
복제본이나 이후 GFS2 시험용 source clone과 혼합하지 않았다. 꺼져 있던 6대의 기존 NIC 연결을
복원하고 실행했으며, 원래 MAC·disk 주소·용량·firmware를 바꾸지 않았다. 기존 Rocky 3대는 이미 실행 중이었다.

| 도구 | OS | IDE | SATA | SCSI | 원본 firmware |
|---|---|---|---|---|---|
| v2k | Ubuntu 22.04 | v2k-tst-ubuntu2204-ide-bios | v2k-tst-ubuntu2204-sata-uefi | v2k-tst-ubuntu2204-scsi-uefi | IDE BIOS / SATA·SCSI EFI |
| v2k | Windows Server 2022 | v2k-tst-win2022-ide-bios | v2k-tst-win2022-sata-uefi | v2k-tst-win2022-scsi-uefi | IDE BIOS / SATA·SCSI EFI |
| v2k | Rocky 9.7 | v2k-tst-rocky97-ide-bios | v2k-tst-rocky97-sata-uefi | v2k-tst-rocky97-scsi-uefi | IDE BIOS / SATA·SCSI EFI |
| n2k | Ubuntu 24.04 | n2k-ubuntu-ide-01 | n2k-ubuntu-sata-01 | n2k-ubuntu-scsi-01 | UEFI |
| n2k | Windows Server 2022 | n2k-win2022-ide-01 | n2k-win2022-sata-01 | n2k-win2022-scsi-01 | UEFI |
| n2k | Rocky 9.7 | n2k-rocky-ide-01 | n2k-rocky-sata-01 | n2k-rocky-scsi-01 | UEFI |

원본의 가상 디스크 합계는 678 GiB다. 이는 Ceph 물리 예약량이 아니다. 최대 VM 72 GiB와
worker 로컬 여유 약 111/192/234 GiB를 고려해 후속 adapter의 staging·안전 여유를 별도 계산한다.

원본과 같은 MAC을 사용하는 **기존 13번 시험 대상 15대(v2k #89 6대, n2k #90 9대)**를
Mold 정상 정지로 보존한 뒤 원본을 실행했다. 대상 이름·UUID·충돌 MAC은 JSON에 있다.
VM/볼륨을 삭제하지 않았고 나머지 13번 자원을 대상으로 조작하지 않았다. 현재 수집한 13/32번
Running VM 인벤토리에서 원본 MAC 및 관측 IPv4와 겹치는 대상이 남아 있지 않음을 확인했다.
이 결과를 전체 외부 네트워크의 충돌 부재로 확대하지 않는다.

**원본을 켠 상태에서 이 15개 GFS2 대상을 다시 실행하지 않는다.** 시험 종료나 복구 시에도 같은
MAC/IP를 공유하는 원본·13번·32번 대상 중 하나만 활성 네트워크에 연결되도록 순서를 지킨다.

## Windows 부팅 자산과 adapter 준비

기존 VirtIO ISO(`/usr/share/virtio-win/virtio-win.iso`)와 qemu-nbd·guestfish·virt-customize·nbdkit을
확인했다. rbd-nbd는 설치돼 있지 않다. 후속 adapter는 현재 있는 도구의 실제 조합을 검증해 선택한다.

WinPE가 없어 공식 [v0.9.5 릴리스](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/releases/tag/v0.9.5)의
`winpe-ablestack-v2k-v0.9.5-amd64.iso`와 SHA256SUMS를 받아 검증해 각 호스트에 별도 설치했다.
이는 도구 0.10.0 RPM에 포함돼 있다고 표시하지 않는 operator-staged 부팅 자산이다.

- SHA-256: `4ca45e7bc407e03a678f3ab6f3fdf4380f4de24443e8e660eeaa3d9c6ecebf78`
- 경로: `/usr/share/ablestack/v2k/winpe/winpe-ablestack-v2k-v0.9.5-amd64.iso`
- current.json과 호환 링크를 함께 구성하고 설치된 resolver의 WinPE/VirtIO 경로 선택을 확인했다.
- ISO 설치는 Windows 실제 boot·driver injection 성공 검증과 구분한다.

RBD preserve용 Linux/Windows guest payload/appliance의 신규 배치·자격은 adapter 구현과 함께
후속 수행한다. Agent capability가 supported라고 이 자산과 raw/RBD 준비 경로까지 지원된 것으로
판정하지 않는다.

## 미리보기와 남은 기능 차이

v2k/n2k 각각 원본 Ubuntu IDE에 실제 `cloud-rbd` wizard `--print-command`를 실행했다.
RBD/raw, cache=none, preallocation=not_applicable, 자동 worker 선택과 2개 disk map을 확인했다.
기본 경로 확인을 위해 **명시적 `--guest-config-policy off`**를 사용했으며 자원 생성·manifest 저장은 없었다.
off로 실제 이관하면 guest 설정 검증 완료로 처리되지 않는다는 기존 계약을 유지한다.

반대로 preserve/RBD/raw 조합은 설치된 코드에서 **GUEST_CONFIG_TARGET_UNSUPPORTED**로
복사 전에 거절됨을 확인했다. 이를 자동 off로 바꾸거나 게이트를 제거하지 않았다.

환경·원본·baseline 미리보기 준비는 완료했으며, 자동 복원 구현과 실제 18대 이관은 운영자의 후속
지시 후 진행한다. #93과 이 Draft PR은 그 후속 검증을 위한 작업 위치로 유지한다.
