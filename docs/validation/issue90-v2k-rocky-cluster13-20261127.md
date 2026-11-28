# Rocky Linux 9.7 v2k 실기 검증 — 13번 GFS2, 2026-11-27

원본 `V2K-Test-20261126` 폴더의 Rocky Linux 9.7 IDE/BIOS·SATA/EFI·SCSI/EFI 3대를 읽기 전용으로 확인하고, `V2K-I90-Rocky-20261127` 폴더의 격리 복제본으로 검증했다. 원본과 복제본 NIC의 MAC을 구별하고 복제본의 VMware NIC는 연결하지 않았다. 인증은 런타임 입력만 사용했다.

## 구현과 적용

- NetworkManager Ethernet keyfile의 UUID·ifname·DHCP/정적 주소·DNS/routes/MTU를 유지한다. MAC 대응과 전용 systemd .link를 준비한다. source의 PyYAML/QGA 설치를 요구하지 않는다.
- Rocky 9.7 vault의 QGA 9.1.0-29.el9_7.6, liburing 2.5-1.el9, numactl-libs 2.0.19-3.el9를 공급자 서명과 고정 키 SHA·RPM SHA로 검증한 뒤 복제본에 오프라인 설치한다. 호스트 RPM DB는 임시 저장소와 분리한다.
- QGA vendor allow list에 guest-file RPC 6개만 더하고 guest-exec 제한을 유지한다. 전용 CIL 정책은 결합 디렉터리만 허용한다. SELinux Enforcing과 전역 boolean off를 유지한다.
- Linux 결합 디렉터리는 오프라인 준비와 서비스의 ExecStartPre에서 0700으로 제한한다. StateDirectory를 사용했을 때 SELinux의 STATE_DIRECTORY 단계가 차단되는 것을 확인하여, 별도의 init 도메인 권한 확대 없이 서비스 실행 단계에서 권한을 적용하도록 했다.
- 현재 관측이 성공하면 이전 GUEST_CHANNEL_UNAVAILABLE reason을 지워 성공 상태에 과거 오류가 남지 않게 했다.
- Mold는 기존 Linux 계약을 재사용한다. 이번 Rocky 확장에 새 Cloud API·DB·Agent 런타임 변경은 없으며 설계 문서와 PR의 실기 범위를 갱신한다.

13.1의 `/var/tmp/issue90/repo-rocky-final`에 PR 소스와 오프라인 자산을 격리 배포하고 실제 production Wizard·Mold API·Agent를 사용했다. 시험 드라이버는 인증 운반만 런타임 세션 proxy로 연결했다. 디스크 복사·반입·컨트롤러 선택·검증 로직은 실제 v2k 함수를 사용했다.

## 최초 자동 이관과 재기동

| 원본 컨트롤러 | 펌웨어 | 대상 컨트롤러 | 최종 Mold VM UUID | 호스트 이동 | 최종 판정 |
|---|---|---|---|---|---|
| IDE | BIOS | SATA/AHCI | 7f213c52-6990-46d4-b771-f11b37335070 | ablecube13-3 → ablecube13-1 | VERIFIED |
| SATA | EFI | SATA/AHCI | 6cc596fc-0c3e-4ea9-b235-bd58a20681dd | ablecube13-1 → ablecube13-2 | VERIFIED |
| SCSI | EFI | VirtIO SCSI | 1e8fbff2-a1af-44bd-94d9-13d4aa1a52ec | ablecube13-2 → ablecube13-3 | VERIFIED |

- 최초 full Wizard 이관은 구현 커밋 `0ee3161`로 수행했고, 3대 모두 complete=true·VERIFIED에 도달했다. 게스트 NIC/IP/디스크/fstab 설정의 수동 복구는 0회다.
- ROOT LVM/XFS와 DATA `/data/v2k` XFS가 인식되었다. 복제본의 ROOT/DATA 검증 파일 각각 163,840바이트 SHA-256을 대조하고, 두 파일시스템에서 새 65,536바이트 파일 생성·fsync·읽기·삭제를 수행했다.
- 6개 볼륨의 qcow2/falloc/writeback과 실제 실행 XML의 디스크 bus·serial·MAC·펌웨어를 확인했다. 처음 기동할 때의 할당 증거와 실행 후 상태를 구분한다.
- 다른 호스트에서 stop/start한 뒤 실제 OS 재부팅도 수행했다. 최종 게스트 boot_id와 현재 Mold 보고서 boot_id가 일치하고 최초 부팅 ID와 다름을 확인했다. 과거 보고서로 성공을 판정하지 않았다.
- 재기동 관측 과정에서 서비스 자산의 private 디렉터리 처리를 보완해 시험 게스트 3대에 배포했다. 동일 helper/plan/operation을 유지하고 현재 클라이언트로 다시 VERIFIED를 받았다. 이는 서비스 코드 배포이며 NIC/IP/디스크/fstab 수동 조정은 하지 않았다. 최신 보완까지 포함한 결과는 첫 이관과 재기동 검증을 구분해 기록했다.
- 최종 3대 모두 SELinux Enforcing, `virt_qemu_ga_read_nonsecurity_files=off`, `virt_qemu_ga_run_unconfined=off`, 결합 디렉터리 0700이다. 일반 사용자 접근 거부와 QGA·NetworkManager·관측 서비스 정상 동작을 확인했다.
- 봉인된 작업 재검증에서 원본 재복사·이미지 재개방·재반입 없이 Mold 현재 상태를 확인했다. ROOT/DATA 파일 SHA와 읽기·쓰기 검사를 재기동 뒤 반복했다.

## 자동 검증과 운영 상태

로컬 관련 테스트 72건(게스트 35, 컨트롤러 12, sealed 재개 5, 이미지 14, Mold handoff 6), 기존 v2k 스모크 8개를 통과했다. SELinux CIL을 격리한 정책 저장소에서 컴파일하고 호스트의 실제 정책에 설치되지 않았음을 확인했다. 초기 구현 커밋의 upstream 도구 CI 7개도 통과했다. 최종 PR Checks는 별도로 확인한다.

Mold 전용 계약 CI는 통과했다. 저장소 전체 빌드는 기존과 같은 RAT 미승인 4,074개에서 실패했다. 이 실패를 Rocky 기능 성공 검사로 표시하지 않는다.

원본 VMware 9대의 UUID·전원·스냅샷 상태와 기존 Mold 117대의 UUID·이름·전원·호스트를 보존했다. 원본 Rocky 3대는 On, 기존 Ubuntu/Windows 6대는 Off이다. 작업 복제본 6대는 Off·스냅샷 0이다. 최종 대상 3대는 Running이고, 초기 진단 대상 3대는 Stopped로 보존했다. Mold 전체는 123대이며 호스트 3대 Up/Enabled, UI HTTP 200을 확인했다. 작업 소스·manifest/log 등 199개 파일의 런타임 인증 문자열 검사 결과 0건이다.

## 자격 범위와 증거

실기는 Rocky 9.7 x86_64·NetworkManager keyfile·DHCP4/IPv6 RA·LVM/XFS ROOT·XFS DATA 범위다. 정적 IPv4/IPv6·DNS/routes/MTU·다중 NIC는 단위 검증으로 구분한다. ifcfg, bond/bridge/VLAN, 인증/VPN, 모호한 대응, Rocky 9.8/RHEL 및 다른 버전은 이번 자격 범위에 포함하지 않는다. 새 공식 Release 또는 전체 오프라인 RPM 설치 인증을 대신하지 않는다.

[상세 JSON](issue90-v2k-rocky-cluster13-20261127.json) · [사용법](../v2k-guest-configuration.md) · [도구 PR #88](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/pull/88) · [Mold PR #1989](https://github.com/ablecloud-team/ablestack-cloud/pull/1989)
