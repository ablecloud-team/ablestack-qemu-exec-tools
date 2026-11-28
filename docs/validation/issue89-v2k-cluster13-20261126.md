# 이슈 #89 v2k 실제 VMware → Mold GFS2 검증

2026-11-26, vCenter 8.0.1의 `V2K-Test-20261126` 폴더에 운영자가 준비한 Windows Server 2022 3대와 Ubuntu 22.04 3대를 13번 Mold/GFS2 환경으로 이관했다. 각 VM은 ROOT와 DATA 2개 디스크다. 이번 #89 구현은 v2k이며 n2k는 후속 범위다.

전송/CBT/최종 차단/Windows WinPE·Linux initramfs 준비는 실제 도구 소스와 VMware를 사용했다. Mold도 실제 API·DB·Agent·GFS2·실행 XML이다. 테스트 실행기는 인증을 RAM에서 처리하기 위해 API 전송만 임시 localhost 프록시로 연결했다. 합성 VMware reader로 대체한 #87 검증과 구분한다. RPM/Release 배포 검증은 아니다.

## 결과

| 원본 | 펌웨어 | 대상 디스크 드라이버 | 호스트 / 인스턴스 | 부팅·해시·ROOT/DATA I/O |
|---|---|---|---|---|
| v2k-tst-ubuntu2204-ide-bios | bios | ahci | ablecube13-1 / i-2-295-VM | PASS |
| v2k-tst-ubuntu2204-sata-uefi | efi | ahci | ablecube13-1 / i-2-297-VM | PASS |
| v2k-tst-ubuntu2204-scsi-uefi | efi | virtio-scsi | ablecube13-3 / i-2-299-VM | PASS |
| v2k-tst-win2022-ide-bios | bios | ahci | ablecube13-1 / i-2-298-VM | PASS |
| v2k-tst-win2022-sata-uefi | efi | ahci | ablecube13-1 / i-2-296-VM | PASS |
| v2k-tst-win2022-scsi-uefi | efi | virtio-scsi | ablecube13-3 / i-2-301-VM | PASS |

[기계 판독 증거](issue89-v2k-cluster13-20261126.json)에 원본 UUID/컨트롤러 주소/장치 키/역할/크기, 계획 해시, 대상 VM/볼륨 UUID, 실행 버스/모델/경로/형식, preallocation 증거와 게스트 파일 해시를 기록했다. IDE 원본은 선택한 auto 정책에 따라 SATA/AHCI가 되며 원본 IDE 정보는 보존한다. SCSI는 VirtIO SCSI다. BIOS/EFI는 원본을 유지했다.

모든 파일은 qcow2/falloc, 오퍼링은 writeback이다. 최종 12개 볼륨의 UUID·역할·장치 번호·크기·풀·경로·형식과 계획/실행 XML을 연결했다. 게스트 검증은 ROOT와 DATA에 사전에 쓴 VM별 파일의 SHA-256 비교 및 새 임시 파일 쓰기/fsync 또는 읽기/삭제다. 전체 디스크 이미지 해시 비교를 의미하지 않는다.

Ubuntu IDE는 phase1→phase2, 나머지는 full 흐름을 사용했다. 실제 VMware VirtualAHCIController의 SATA selector를 보완했고 세 종류 모두 base/incremental/final CBT coverage와 장치 키를 확인했다. 소스는 최종 poweredOff, 임시 migration snapshot은 0개다.

## 발견 및 보완

- 메모리 풍선 장치용 별도 `<devices>` 구역 때문에 최종 검증이 writable disk를 0개로 판단하던 문제를 수정했다. 메타데이터의 동명 구역과 실제 장치 구역을 구분하고 libvirt 정규화 이후 실제 컨트롤러 주소/모델도 검증한다.
- Windows SCSI의 최초 32포트 q35 배포에서는 `ACPI_BIOS_ERROR`가 발생했다. 원본 Windows 계열에 맞는 기존 `q35-windows-16-v1` 프로파일을 최초 생성 요청에 명시하도록 보완했다. 새 배포에서 16포트, 부팅, VirtIO SCSI, 해시/I/O를 확인했고, 동일 VM을 13-2에서 정지한 뒤 기존 오류가 났던 13-3에서 다시 시작해 재확인했다. 실패 대상 1대와 두 볼륨은 운영자 승인 후 삭제했고 실제 API/파일 부재를 확인했다.
- Ubuntu IDE의 최초 기동에서 I/O timeout이 한 차례 관측됐다. 재시작 이후 실제 ROOT/DATA I/O와 후속 작업 중 재확인은 통과했다. 최초 현상의 원인이 해결됐다고 단정하지 않는다.
- 일반 VM 세부 정보 갱신으로 계획이 유실되는 경우를 막고, 숨김/표시 상태 모두에서 migration 메타데이터를 유지한다. 잘못된 임시 설정은 정지 상태에서 복구한 후 검증했다.
- 실제 wizard phase2/full 재개를 다시 실행했다. Mold 반입 이후에는 원본 snapshot/증분/최종 패치와 오프라인 부팅 준비를 건너뛰고, 동일 볼륨과 실행 XML을 API로 재확인한다. cutover 완료 마커도 실제 CLI 경로에서 기록했다. 별도 byte-plane 호출은 코드 44로 차단한다.

## 게스트 OS 조정과 한계

Ubuntu 3대는 VirtIO NIC 전환으로 인터페이스 이름이 바뀌어 원본 네트워크 설정이 활성화되지 않았다. 디스크 부팅/마운트/I/O는 콘솔 로그인으로 검증했다. NIC 이름에 고정된 게스트 네트워크 설정 조정은 남아 있으며 디스크 드라이버 기능 완료와 구분한다.

Windows SCSI DATA는 OS의 `OfflineShared` 정책으로 offline/read-only였고 빈 두 번째 CD-ROM이 E:를 사용했다. 검증에서는 **반입 DATA의 고유 ID와 GPT 파티션 GUID를 일치시킨 뒤 그 디스크만** online/read-write로 전환하고, 빈 CD-ROM의 문자를 옮겨 원본 E:를 복원했다. 전역 SAN 정책은 바꾸지 않았다. 재시작 후에도 추가 조정 없이 E:와 데이터 I/O가 유지됐다. 이 게스트 내부 조정은 이번 v2k 제품 코드에서 자동 수행하지 않으며 운영 절차로 기록한다.

이 결과는 지정한 VMware/운영체제 6개 사례다. 모든 ESXi/AOS/Windows 버전, 임의 원형 IDE/LSI 모델, 모든 혼합 디스크 구성의 실부팅을 검증했다는 뜻이 아니다. 혼합 구성/불명확 ROOT/다수 장치명/잘못된 모델·경로·형식은 자동 회귀 검증 범위다. 첫 기동 뒤 preallocation 증거는 이력이며 지속적인 물리 extent 고정을 보장하지 않는다.

## 자동 검증과 환경 보존

- Cloud: 41개 관련 Maven 모듈 package, 이관 계약 테스트 164건(새 컨트롤러 테스트 19건 포함) 통과.
- 도구: 컨트롤러/실제 wizard 메뉴/ROOT 선택 테스트 12건, sealed 재개 테스트 5건, 실제 이미지/CLI/Wizard preallocation 14건, Mold handoff 6건 통과. 관련 기존 회귀 13개(공유 VMware DR baseline 포함)도 통과했다.
- 관리 서버와 Agent 3대에는 필요한 클래스만 원본 해시 검증 및 백업 후 반영했다. WEB-INF와 나머지 jar 엔트리는 보존했다. source 실행은 13-1의 별도 작업 경로를 사용했다.
- 기존 Mold VM 100대의 UUID/이름/상태/호스트 변경 0, 최종 이관 VM 6대 Running, 호스트 3대 Up/Enabled, Mold UI HTTP 200을 확인했다. 원본 6대는 중복 MAC/IP 기동을 피하도록 poweredOff로 보존한다.
