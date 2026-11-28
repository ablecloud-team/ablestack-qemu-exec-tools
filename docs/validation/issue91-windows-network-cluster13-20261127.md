# 이슈 #91 Windows IPv4 자동 복원 실기 검증

2026-11-27, 기존 도구 PR #88과 Mold PR #1989의 Windows 네트워크 보존을 13번 GFS2에서 검증했다. VMware/Nutanix Windows Server 2022 build 20348의 IDE·SATA·SCSI 각 3대, 총 6대가 자동 복원과 다른 호스트에서의 stop/start 후 현재 관측을 통과했다. 대상 NIC/DATA 설정을 수동 변경한 횟수는 0이다.

## 실제 배포 결과

| 경로 | 원본/펌웨어 | 대상 컨트롤러 | 정적 IPv4 | 최종 Mold VM UUID | 호스트 이동 | 판정 |
|---|---|---|---|---|---|---|
| n2k | IDE/EFI | sata | 10.10.21.71/16 | `84fcaee4-c488-4572-9f7a-0a2f29a7b7a7` | ablecube13-2 → ablecube13-3 | VERIFIED |
| n2k | SATA/EFI | sata | 10.10.21.72/16 | `062821fe-484f-4c64-a429-a9bddf8a8397` | ablecube13-3 → ablecube13-1 | VERIFIED |
| n2k | SCSI/EFI | virtio-scsi | 10.10.21.73/16 | `cb18d9cd-8ceb-47d0-bcc0-839a2157a7a8` | ablecube13-1 → ablecube13-2 | VERIFIED |
| v2k | IDE/BIOS | sata | 10.10.21.81/16 | `d3d86ed3-f329-4573-964f-8f97f2cb89d9` | ablecube13-1 → ablecube13-2 | VERIFIED |
| v2k | SATA/EFI | sata | 10.10.21.82/16 | `6850c424-ed21-4116-ad56-0e00a00a0539` | ablecube13-2 → ablecube13-3 | VERIFIED |
| v2k | SCSI/EFI | virtio-scsi | 10.10.21.83/16 | `5182a750-b7a4-41b2-afd9-0de91df8d05b` | ablecube13-3 → ablecube13-1 | VERIFIED |

- 공통 gateway는 `10.10.0.1`, DNS는 `8.8.8.8 → 8.8.4.4`, route metric은 256이며 interface metric의 자동 정책을 유지했다.
- 새 Windows InterfaceGuid/PnP/ifIndex를 실제 대상 MAC과 Mold NIC UUID/network UUID에 결합했다. 호스트 이동 후 ifIndex가 바뀐 IDE도 같은 정적 설정을 유지했다.
- 모든 guest report와 Mold 판정이 v2/VERIFIED다. 최초/재시작의 boot ID·boot scope가 달라졌고 같은 plan hash/operation ID를 유지했다.
- ROOT/DATA 총 12개는 qcow2/falloc이며 실제 실행 XML의 controller·firmware·cache=writeback과 QGA channel을 확인했다. Windows DATA는 v2k의 원래 E:, n2k의 원래 T:와 online/RW를 유지했고 전역 OfflineShared SAN 정책도 같았다.
- 각 guest에서 ROOT/DATA마다 64 KiB 시험 파일을 생성해 fsync, byte-for-byte readback과 SHA-256을 확인한 후 해당 시험 파일만 제거했다. 초기는 fsync/readback, 최종 호스트 이동 후에는 SHA-256도 확인해 JSON에 구분했다.

## 원본 준비와 IP 충돌 확인

기존 원본/완료 VM을 보존하기 위해 사설 시험 복제본을 사용했다. Nutanix 원본 설정은 71~73/16이었다. VMware 복제본은 DHCP였으므로 운영자가 지정한 81~83/16과 gateway/DNS로 원본 시험 조건을 구성했다. 이는 이관 전 source fixture 준비이며 대상 게스트 설정을 수동 보정한 작업이 아니다.

운영자 허용 범위는 10.10.21.71~99, 우선 후보는 81~83이었다. vCenter 41대·Prism 13대·Mold 133대의 주소 기록에 후보 중복이 없었고 bridge0의 주소별 ARP DAD 4회 응답 0·ICMP 무응답을 확인했다. 실제 적용 후 Windows AddressState=Preferred까지 확인했다. 이 기록은 조회한 인벤토리와 당시 관측 범위의 결과다.

## 검증 중 보완한 경로

1. Windows source NIC/IP/gateway/DNS 수집과 공통 plan/helper/report v2를 추가했다. n2k OS 판정은 계정명 대신 명시적인 source OS 선택/메타데이터를 사용한다.
2. VMware의 advanced NIC CIM 조회가 없는 드라이버는 해당 PnP network class/InterfaceGuid를 교차 확인하는 고정 registry 읽기로 지원 범위를 판별한다. Windows/vSphere SMBIOS UUID는 정확히 일치하거나 해당 BIOS UUID의 알려진 byte-order 표현만 허용하고 raw guest UUID도 보존한다.
3. 자동 metric의 null이 반입 저장에서 누락되는 경로를 수정했다. 원래 hash가 정확히 재현되는 null 누락만 읽기에서 복원하며 저장된 정책/hash를 바꾸지 않는다.
4. 실제 선택된 Agent를 확인하는 VM 시작 경로도 v2를 요청하고 같은 버전·필수 기능의 응답을 요구하도록 보완했다.
5. 이전 NIC를 정확히 제거한 뒤 남은 TCP/IP 백업 키만으로 점유 상태를 단정하지 않는다. PnP·NetAdapter·CIM 등록이 모두 없을 때만 해제된 인터페이스로 관찰하고 백업 키는 삭제하지 않는다. 실제 재부팅 필요는 최대 1회와 새로운 binding challenge로 제한한다. 모의 실행에서 3010·실패 코드·같은 QEMU PID의 challenge를 검증했다.
6. 최초 SATA·SCSI 실패 대상은 FAILED로 유지했고 수동 IP 수정이나 계획/helper 교체로 성공 처리하지 않았다. 새 MAC/새 작업으로 다시 검증했다. 기존 실패 VM 2대는 Stopped로 보존하며 정상 6대에 포함하지 않는다.
7. GFS2 작업 중 storage worker가 BUSY인 시도는 완료시키지 않았다. 같은 sealed 작업을 API로 재개했으며 source 재복사·관리 이미지 재개방을 하지 않았다.

## 검증 범위와 회귀

- 도구: guest Python 40건, n2k 17건, Windows storage 6가지/network 11가지 모의 실행, shellcheck 및 기존 controller/sealed/image/handoff 검사.
- Mold: 전용 CI와 같은 16개 suite/194건, 실패·오류·skip 0. 도구 원격 CI 7개와 Mold 전용 contract도 통과했다.
- 기존 Ubuntu/Rocky n2k 6대를 v1 계약으로 새로 관측했고 모두 VERIFIED다.
- 지원 실기는 Windows Server 2022 build 20348, GFS2/file-qcow2, L2/plain Ethernet/정적 IPv4다. DHCP 조합·오류 경계는 단위/모의 실행이며 다중 NIC·복수 IPv4는 실기 자격에 포함하지 않는다. 다른 Windows 버전·수동 IPv6·IPAM·복잡한 NIC 및 공식 전체 오프라인 신규 Release 설치 자격을 주장하지 않는다.
- 기존 v1 Windows DATA-only 기록은 자동 업그레이드하지 않았다. 현재 6대는 새 v2 이관 작업이다.

## 환경 보존과 배포

기존 Mold VM 132대의 UUID·이름·전원·호스트 변경은 0건이다. 최종 140대는 기존 132대와 정상 신규 6대, 보존된 실패 2대다. Agent 3대는 Up/Enabled, management service active, UI HTTP 200, WEB-INF 유지 상태다. 새 DB table/column은 없다.

관리 서버/Agent는 원본 jar를 백업하고 필요한 class만 반영했으며 나머지 entry 내용은 비교해 보존했다. source coordinator에는 동일 브랜치의 text runtime/payload를 설치했다. ISO를 수정하거나 신규 공식 Release를 배포하지 않았다. VMware 원본/시험 복제본과 Nutanix 원본/시험 복제본의 상태는 JSON에 기록했다. 시험 Windows source 6대는 OFF이며 VMware migration snapshot은 0개다. 재개 경로에 남은 Nutanix IDE 소유 recovery point 3개도 source UUID/기록을 검증한 뒤 제품 cleanup 함수로 정리했다.

런타임 인증은 메모리로 전달했다. 최종 소유 text artifact 411개 검사에서 인증 문자열 일치 0건이다. 이미지/동영상 진단 파일을 만들지 않았다.

Mold 저장소 전체 build는 기존과 같은 RAT 미승인 4,074개에서 실패한다. 전용 기능 contract 통과와 구분하며 전체 build 성공으로 표기하지 않는다.

[상세 JSON](issue91-windows-network-cluster13-20261127.json) · [이슈 #91](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/91) · [도구 PR #88](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/pull/88) · [Mold PR #1989](https://github.com/ablecloud-team/ablestack-cloud/pull/1989)
