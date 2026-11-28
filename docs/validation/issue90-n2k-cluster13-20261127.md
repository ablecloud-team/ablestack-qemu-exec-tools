# n2k 9대 Wizard 이관 검증 — 13번 GFS2, 2026-11-27

Nutanix CE PC 7.3.1.18(`10.10.21.90:9440`)/PE 7.0.1.15(`10.10.21.97:9440`)의 Windows Server 2022 build 20348·Ubuntu 24.04.5·Rocky Linux 9.9 각 IDE/SATA/SCSI, 총 9대를 production n2k Wizard로 Mold 13번 클러스터에 이관했다. 9대 모두 UEFI이며 ROOT+DATA 18개·222 GiB다. 인프라 VM `n2k-pc-01`은 제외했다. 인증은 런타임 입력으로만 전달했다.

## 최종 결과

| 원본 | 컨트롤러 정책 | Mold VM UUID | 최종 호스트 | 판정 |
|---|---|---|---|---|
| n2k-rocky-ide-01 | IDE → SATA/AHCI | `9eeb92c5-f622-497b-b587-6ee65a81a8f1` | ablecube13-3 | VERIFIED |
| n2k-rocky-sata-01 | SATA → SATA/AHCI | `60265de8-9534-47a2-beaf-c33150124a15` | ablecube13-3 | VERIFIED |
| n2k-rocky-scsi-01 | SCSI → VirtIO SCSI | `fcba80ae-451f-42a3-bbbc-f9e1313a2c1a` | ablecube13-1 | VERIFIED |
| n2k-ubuntu-ide-01 | IDE → SATA/AHCI | `81f30ab2-6da7-49f9-bb3e-2284a0ee535a` | ablecube13-2 | VERIFIED |
| n2k-ubuntu-sata-01 | SATA → SATA/AHCI | `072a050a-8582-44d7-9edd-b0ff10c333ab` | ablecube13-1 | VERIFIED |
| n2k-ubuntu-scsi-01 | SCSI → VirtIO SCSI | `e139c4f9-c813-4d16-95a0-6bdd9bc6ce3c` | ablecube13-2 | VERIFIED |
| n2k-win2022-ide-01 | IDE → SATA/AHCI | `eb6525bf-4678-476f-af01-347a0afee7f5` | ablecube13-2 | VERIFIED |
| n2k-win2022-sata-01 | SATA → SATA/AHCI | `9bc36fcb-b340-4fb4-9c78-1e3edf8b8333` | ablecube13-3 | VERIFIED |
| n2k-win2022-scsi-01 | SCSI → VirtIO SCSI | `b983fc13-304d-4a96-8d35-649659ba4ecf` | ablecube13-1 | VERIFIED |

- 9대 모두 Running, 실제 실행 XML 컨트롤러 검증과 게스트 설정 VERIFIED를 확인했다. ROOT/DATA 18개는 qcow2/falloc/writeback이며 실제 XML cache도 writeback이다.
- 다른 호스트에서 정지/시작한 뒤 현재 binding/보고서로 재검증했다. 원본·반입 이미지를 다시 열지 않는 봉인 재개와 표준 설치된 `/usr/local/bin/ablestack_n2k wizard`를 확인했다.
- Linux는 VM별 ROOT 메타데이터 2개와 DATA 36개 파일, Windows는 DATA 36개 파일의 원본 SHA를 대조했다. VM별 ROOT/DATA에서 각 65,536바이트 생성·fsync·읽기·삭제를 검증했다. 한 회차 336개 파일과 18개 파일시스템의 I/O를 확인하고 호스트 재기동 뒤 반복했다.
- Ubuntu/Rocky는 정적 IPv4·원래 ifname·MAC·gateway/DNS·DATA `/mnt/n2k-data`를 확인했다. Rocky는 SELinux Enforcing과 제한된 QGA 파일 RPC를 유지했다. Windows DATA는 이번 원본의 `T:`/N2K-DATA를 보존했고 online/RW 및 OfflineShared SAN 정책을 확인했다.
- 기존 Mold VM 123대의 ID·이름·전원·호스트를 보존했다. 최종 132대, 호스트 3대 Up/Enabled, UI HTTP 200이다.

## 발견 오류와 보완

1. PC v3/v4 device UUID와 PE 실제 vDisk UUID가 달라 동일 크기 ROOT/DATA의 source-map이 실패했다. PE v2의 device UUID·컨트롤러 주소·크기로 연결하고 canonical DATA vDisk만 snapshot/NFS 후보에 남겼다. CD-ROM을 위해 NFS allowlist를 넓히지 않았다.
2. Ubuntu Netplan의 논리 키 `n2k`를 실제 ifname으로 해석하던 경로를 수정해 관측된 ens3를 유지했다. Rocky는 활성 keyfile UUID를 수집하고 동일 MAC의 고우선순위 cloud-init 생성 ifcfg만 백업·자동 연결 해제 후 원래 profile을 적용한다.
3. 파티션 없이 만든 ext4/XFS DATA에 partition-table API를 강제하던 경로를 수정했다. 파일시스템 UUID로 식별하며 초기화/포맷하지 않는다.
4. Windows IDE 첫 시도는 NTFS 최대 절전 상태로 오프라인 쓰기가 차단되어 Mold에 반입하지 않았다. 지정된 테스트 원본을 운영자가 한 번 기동해 정상 상태를 확보하고 새 r2 작업으로 다시 이관했다. 제품은 UUID를 확인한 WinRM 완전 종료 요청과 Prism OFF 확인을 사용하며, 실패한 원본을 자동 기동하지 않는다.
5. AHV Windows의 VirtIO serial driver를 준비하고 설치된 VirtIO RPM file digest와 Windows catalog enforcement를 사용했다. 32비트 firstboot 서비스에서 pnputil을 찾지 못한 실제 로그를 확인해 Sysnative로 64비트 cmd/PowerShell을 사용하도록 수정했다. 반입된 3대에는 같은 수정 코드를 SYSTEM task로 온라인 반영했다. observer helper/operation/계획 해시와 볼륨을 유지하며 재개했고, 수동 NIC/IP/DATA/드라이브 문자 값 조정은 하지 않았다.
6. bounded Linux observer가 종료한 뒤 지연 재조회에서 stale report가 남는 경우를 재현해 path와 함께 timer로 관측을 재기동했다. VERIFIED journal 이후 network preparer는 설정을 적용하지 않는다. guest-exec나 전역 SELinux boolean을 열지 않았다.
7. Windows는 host start 직후 RTC/시간 서비스 보정으로 나중에 조회한 Win32 부팅 시각이 달라졌다. 보고서의 boot_id를 startup token으로 다루고, 이전 토큰과 달라졌는지와 현재 binding SHA/scope·실제 VM/ROOT를 함께 확인했다. 과거 보고서를 새 성공으로 승격하지 않았다.

## 배포와 검증 경계

기존 `codex/issue-87-mold-preallocation`, [도구 PR #88](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/pull/88), [Mold PR #1989](https://github.com/ablecloud-team/ablestack-cloud/pull/1989)에서 진행했다. Mold의 기존 generic plan/binding/report API·Agent 계약을 재사용해 신규 API/DB/Agent Java 변경은 없다. 13.1 변환 worker의 실행 코드를 백업 후 반영하고 private transport runtime과 검증된 오프라인 자산을 표준 경로에 배치했다. 공식 RPM 버전 변경/Release를 대신하지 않으며 실행 파일 SHA로 추적한다.

초기 오류가 있었으므로 9대 모두 첫 시도 성공으로 표기하지 않는다. Ubuntu IDE는 반입 전 보완/재개, Rocky IDE는 준비 서비스 코드 갱신, Windows 3대는 native firstboot 코드 갱신 후 같은 봉인 작업의 자동 VERIFIED를 확인했다. 이후 다른 호스트 재기동·표준 설치 client의 재개·파일 SHA/I/O를 별도로 검증했다.

Windows 원본 정적 IP의 자동 복원은 현재 v1 DATA adapter 범위에 포함하지 않는다. 시험 대상은 새 VirtIO NIC의 DHCP 주소로 접근했다. Linux 실기는 plain Ethernet/정적 IPv4, Ubuntu Netplan networkd와 Rocky NetworkManager keyfile이다. 복잡한 네트워크·추가 버전·직접 libvirt/RAW/RBD guest 복원 및 공식 전체 오프라인 RPM 설치 자격은 포함하지 않는다.

[기계 판독 증거](issue90-n2k-cluster13-20261127.json) · [사용법과 지원 범위](../n2k/guest_configuration.md)


## 검사·정리 기록

관련 unit/contract 89개(guest 35, controller 12, 이미지/Mold handoff 20, sealed resume 5, n2k 추가 17)와 n2k/v2k smoke 각 4개를 통과했다. 32비트 cmd에서 production firstboot prologue를 사용한 실제 probe도 AMD64 및 System32 pnputil 경로를 확인했다. 런타임 인증 문자열이 실행 소스·manifest/log에 남지 않았는지 검사했다.

원본 workload 9대는 최종 OFF이며 인프라 n2k-pc-01은 ON이다. 완료된 작업의 기록된 recovery point를 정리했다. 최초 Windows IDE 진단 시도의 source snapshot 3개와 비관리 실패 복제본은 진단 근거로 보존한다. 이 자료를 정상 Mold VM으로 집계하지 않는다. 정적 분석/단위 검증과 실기 자격을 구분하며 전체 신규 공식 Release 설치 인증을 주장하지 않는다.
