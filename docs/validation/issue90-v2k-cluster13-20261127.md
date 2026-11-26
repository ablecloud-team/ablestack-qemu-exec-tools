# 이슈 #90 v2k → Mold 게스트 설정 자동 복원 검증

2026-11-26~27, 13번 GFS2에서 VMware 원본의 새 클론 6대를 실제 v2k Wizard와 Mold로 이관했다. 첫 자동 완료 전에 콘솔·SSH·WinRM으로 게스트 NIC/디스크 설정을 조정한 횟수는 0이다. 인증 전송만 RAM 기반 localhost 세션 프록시로 연결했고 이관·Mold·Agent·QGA·스토리지는 실제 코드와 환경을 사용했다.

| 원본 유형 | 펌웨어 | 대상 드라이버 | 인스턴스 / 이동 후 호스트 | 자동 결과 |
|---|---|---|---|---|
| Ubuntu 22.04 IDE | bios | ahci | i-2-312-VM / ablecube13-1 | VERIFIED: ens192 / MAC / DHCP4 |
| Ubuntu 22.04 SATA | efi | ahci | i-2-311-VM / ablecube13-2 | VERIFIED: ens192 / MAC / DHCP4 |
| Ubuntu 22.04 SCSI | efi | virtio-scsi | i-2-310-VM / ablecube13-1 | VERIFIED: ens192 / MAC / DHCP4 |
| Windows Server 2022 IDE | bios | ahci | i-2-307-VM / ablecube13-2 | VERIFIED: DATA online/RW / E: / SAN 유지 |
| Windows Server 2022 SATA | efi | ahci | i-2-308-VM / ablecube13-1 | VERIFIED: DATA online/RW / E: / SAN 유지 |
| Windows Server 2022 SCSI | efi | virtio-scsi | i-2-309-VM / ablecube13-3 | VERIFIED: DATA online/RW / E: / SAN 유지 |

[기계 판독 증거](issue90-v2k-cluster13-20261127.json)에 source/target UUID, 역할·controller·GUID·serial, 계획/operation/helper 해시, 최초 부팅과 다른 호스트 재기동의 boot ID 및 관측을 기록했다. 각 게스트의 ROOT/DATA 검증 파일 SHA-256과 새 임시 파일 쓰기·fsync/Flush·읽기·삭제를 최초 완료 뒤와 호스트 이동 뒤에 대조했다. 12개 볼륨은 qcow2/falloc·writeback 정책을 유지했다. 전체 디스크 이미지의 동일 해시를 뜻하지 않는다.

## 적용과 검증

- Source guest probe → 버전/해시가 있는 계획 → 비관리 복제본의 Netplan/firstboot/QGA 준비 → 사전 할당 재검증 → Mold import/binding → 현재 게스트 VERIFIED 순서다. 반입 이후 재조회는 원본 재복사나 guestfs 주입을 실행하지 않았다.
- Ubuntu의 MAC/ifname 연결과 cloud-init 네트워크 생성만 조정했다. Windows는 SYSTEM startup 작업으로 해당 DATA만 조정했고 전역 `OfflineShared` SAN 정책을 유지했다.
- Windows SCSI의 실제 변경은 journal에 남았다. 재기동/호스트 이동 후에는 기존 적용 journal을 유지하고 읽기 전용으로 관찰했다.
- 최초 자동 VERIFIED 증거를 고정한 뒤, Windows SCSI 검증 VM의 E:를 P:로 바꾸는 사용자 변경 시험을 별도로 수행했다. API/CLI는 DRIFT·코드 78을 반환했고 P:와 journal 4단계를 유지했다. 검증용 변경을 E:로 정리한 후 같은 operation의 읽기 전용 재조회가 VERIFIED로 돌아왔다.
- Ubuntu 3대의 관측기를 완료 뒤 의도적으로 중지했다. systemd.path는 active를 유지했고 새 binding/commit 요청만으로 서비스가 다시 실행돼 같은 operation이 VERIFIED로 돌아왔다. Netplan 재적용이나 게스트 수동 수정은 없었다.
- 관리 서버와 Agent 재시작 후 Windows도 같은 operation의 새 관측으로 VERIFIED를 재확인했다.
- 실제 Windows QGA의 EOF 방식, PowerShell의 nullable string 처리, NTFS ACL 상속, 시간 보정에 따른 실행 제한을 검증해 보완했다. 최소 WinPE에 PowerShell을 추가하거나 기존 ISO를 재작성하지 않았다.

## 빌드와 배포

- Cloud 관련 41개 Maven 모듈 package와 기존 164건 및 게스트 계약 22건, 총 186개 계약 테스트를 검증했다. Windows EOF/상한·partial commit·과거 보고서·실제 channel·worker hash·불완전 결합을 포함한다.
- 도구: guest 정책/인증/preview/timeout/frozen 테스트 23건, Windows 저장소 어댑터 모의 실행 6가지, 기존 controller 12건, sealed 재개 5건, 실제 이미지/CLI/Wizard 14건, Mold handoff 6건을 확인했다. Windows 어댑터는 순서 변경, 의도적 offline/RO, 미디어 충돌, 소유 변경 보상, 외부 변경 충돌, RO의 일시 RW 해제 금지를 포함한다.
- 관리 서버와 Agent 3대는 원본 jar 해시 확인·백업 후 필요한 클래스만 반영했다. 다른 jar 엔트리와 WEB-INF는 보존했다. #90에 새 DB 테이블/컬럼은 없다.
- 사설 upstream libguestfs/guestfish 1.58.1, appliance, Ubuntu 오프라인 QGA, Windows QGA 110.2.3과 배포판 firstboot 실행기를 사용했다. 기존 시스템 libguestfs와 ISO는 교체하지 않았다.
- 격리 RPM 구성 빌드와 native 파일 SHA 보존을 확인했다. 큰 appliance는 원본 압축 archive로 배포하고 sparse 캐시로 추출하는 경로를 검증했다(캐시 검증 peak RSS 약 83 MB). 공식 Release·전체 오프라인 RPM 설치 인증은 이번 실기 범위에 포함하지 않는다.

## 환경 보존과 자격 범위

기존 Mold VM 106대(정상 100대와 #89 대상 6대)의 UUID/이름/상태/호스트 변경은 0건이다. VMware 원본 6대와 시험용 source 클론 6대는 최종 poweredOff·migration snapshot 0개다. 성공 대상 6대는 Running이며 Agent 3대는 Up/Enabled다. 초기 실패 대상 `i-2-305-VM`, `i-2-306-VM`과 최신 감시 설정 검증으로 대체한 초기 Ubuntu 대상 3대는 정지 상태로 보존했다. 최종 성공 대상은 표의 6대이며 초기 시험본을 중복 성공으로 세지 않았다.

실기 Linux 범위는 Ubuntu 22.04 networkd DHCP4 및 IPv6 RA이고, 정적 주소·다중 NIC는 단위 검증 범위다. 실기 Windows DATA는 basic GPT/NTFS·E:·online/RW이며 의도적 offline/RO와 충돌/보상은 저장소 어댑터 모의 실행으로 구분했다. 폴더 mount path와 복잡한/인증 포함 Netplan은 명시적으로 차단한다. 직접 libvirt·RBD/raw와 n2k 게스트 자동 복원은 이 검증의 완료 범위가 아니다.

사용법과 경계는 [게스트 설정 자동 복원 안내](../v2k-guest-configuration.md)에 정리했다.
