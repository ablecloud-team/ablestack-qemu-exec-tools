# n2k Mold 게스트 설정 및 디스크 정책 검증

새로운 Mold/GFS2 qcow2 작업은 `--guest-config-policy preserve`와 `--target-preallocation falloc`을 기본으로 사용한다. Wizard와 run/init에서 같은 정책을 사용한다. 원본 IDE는 SATA/AHCI로, SATA는 SATA/AHCI로, SCSI는 VirtIO SCSI로 전환하는 `--target-disk-controller auto`가 기본이다. 원본 장치 ID와 PE의 실제 vDisk UUID는 별도로 기록한다.

## 입력 및 원본 확인

- `--source-guest-user`, `--source-guest-host`, `--source-guest-password-fd`로 별도 게스트 인증을 제공한다. 비밀번호는 런타임 환경 또는 FD로만 전달한다.
- Linux SSH는 기존 known_hosts 또는 `--source-guest-hostkey-sha256`의 64자리 소문자 hex SHA-256 키 지문을 검증한다. 대화형 Wizard는 처음 접속할 키 지문을 확인한다. `--yes`로 알려지지 않은 키를 자동 신뢰하지 않는다.
- `--guest-config-map-json`으로 검증한 원본 상태를 제공할 수 있다. `--guest-config-timeout`은 1..1800초이며 기본 600초다.
- 원본 DMI UUID가 선택한 Nutanix VM UUID와 같아야 상태를 수집한다. Windows는 WinRM/NTLM, Linux는 SSH/sudo를 사용한다. 현재 자동 Windows 수집은 Administrator 계정과 Server 2022 build 20348을 검증했다. 다른 관리 계정/전송 설정은 별도 자격 확인이 필요하다.
- PC v3/v4의 장치 UUID를 PE v2의 `device_uuid`·컨트롤러 주소·크기에 연결한 뒤 실제 `vmdisk_uuid`를 사용한다. 동일 크기 ROOT/DATA를 크기나 배열 순서만으로 선택하지 않는다. CD-ROM/보조 스냅샷 파일은 데이터 디스크 목록에서 제외한다.

## 준비와 완료

최종 복사 전 원본 의도를 다시 수집한다. Windows는 인증한 원본 UUID를 확인하고 WinRM으로 완전 종료를 요청한 뒤 Prism의 OFF 확인을 기다린다. 최대 절전/불완전 종료 NTFS는 오프라인 쓰기 전에 차단한다. 제품이 오류 복구를 위해 원본을 자동 기동하지 않는다.

반입 이전의 정지 복제본에만 helper/QGA와 설정을 준비한다. Ubuntu 22.04/24.04 Netplan과 Rocky 9.7/9.9 NetworkManager Ethernet keyfile을 지원한다. 원래 활성 profile UUID를 유지하고, 충돌하는 cloud-init 생성 ifcfg만 MAC·이름·허용 필드 검증 후 백업하고 자동 연결을 해제한다. 다른 사용자 설정은 자동 정리하지 않는다. 파티션 없이 ext4/XFS를 사용하는 DATA도 식별한다.

Rocky에 설치된 QGA는 원본 RPM 무결성과 복제본 설정 SHA가 검증된 경우 재사용한다. 필요한 파일 RPC만 추가하며 guest-exec 제한과 SELinux Enforcing을 유지한다. Linux 관측은 bounded service와 path/timer로 재개하며, VERIFIED journal 이후 네트워크를 다시 적용하지 않는다.

Windows는 검증한 MSI와 설치된 VirtIO 패키지의 파일 digest 및 Windows catalog 검사를 사용한다. 32비트 firstboot 서비스에서도 Sysnative를 통해 64비트 pnputil/PowerShell을 실행한다. SYSTEM startup 작업이 실제 binding을 확인한 뒤 지정된 DATA만 online/read-write·원래 드라이브 문자로 복원한다. 전역 SAN 정책은 바꾸지 않는다. Windows NIC의 원래 정적 IP 복원은 이 v1 DATA adapter의 범위에 포함하지 않는다. 이번 AHV 시험은 새 VirtIO NIC의 DHCP 주소로 접근했다.

Mold의 실제 XML·ROOT/DATA UUID·형식·슬롯·펌웨어와 QGA 보고서가 VERIFIED여야 완료한다. Running만으로 완료하지 않는다. 첫 import 요청 UUID가 기록되면 원본 재복사·guestfs 준비·snapshot 생성/sync를 차단하고 Mold API로 재개한다. 기존 구형 manifest와 명시적인 `off`는 게스트 복원 미검증으로 구분한다. `--print-command`는 게스트 수집/변경이나 비밀번호 FD 소비를 하지 않는다.

## 실행 환경 및 자격 범위

n2k RPM/DEB에는 같은 소스에서 복사한 공통 정책/게스트 helper를 포함한다. 네이티브 libguestfs·appliance·OS별 QGA·Windows catalog payload는 자격 검증된 별도 실행환경이 필요하다. `N2K_PYTHON_BIN`으로 transport interpreter를 지정하거나 설치 경로의 private runtime을 사용할 수 있다. Guest payload 기본 경로는 기존 `/usr/share/ablestack/v2k/guest-config`이며 Ubuntu 버전에 따라 ubuntu22/ubuntu24를 선택한다. wire v1의 V2K 파일 경로는 Mold 호환성을 위해 유지한다.

[13번 GFS2 검증 결과](../validation/issue90-n2k-cluster13-20261127.md)에 최초 실행·보완 코드 반영·재개·다른 호스트 재기동 결과를 구분한다. 공식 Release/전체 오프라인 RPM 설치 인증, 직접 libvirt 및 RAW/RBD의 새 guest 복원 자격과 구분한다.


## Windows IPv4 자동 복원 계약 v2 (#91)

신규 Windows Server 2022(build 20348) 작업의 `--guest-config-policy preserve`는 DATA와 함께 NIC의 정적 IPv4/prefix, 기본 게이트웨이·route metric, 자동/수동 interface metric 정책, DNS 방식·서버 순서를 보존한다. 원본이 DHCP이면 lease 숫자를 고정하지 않고 DHCP 방식을 유지한다. IP의 DHCP 여부와 DNS의 자동/수동 여부는 별개다.

공통 읽기 전용 probe는 VMware Tools Guest Operations 또는 Nutanix의 승인된 WinRM으로 실행한다. source NIC MAC·InterfaceGuid·PnP 정보를 수집하고 원본 VM UUID를 검증한다. VMware Windows의 SMBIOS UUID 표현은 원본 vCenter BIOS UUID와 일치하거나 그 UUID의 알려진 byte-order 표현인 경우만 수용하며 원래 guest 표현도 기록한다.

Nutanix는 OS를 계정명으로 추정하지 않는다. 인벤토리에서 OS를 확인할 수 없는 비대화형 작업에는 `--source-guest-os windows` 또는 `linux`를 지정한다. Wizard는 OS를 선택받고 이후 SSH/WinRM 인증을 수집한다. 미리보기는 probe 실행·비밀번호 FD 소비 없이 명령과 미검증 항목을 출력한다.

계획/helper/report/binding의 v2와 `windows-network-ipv4-v1` 기능을 관리 서버·실제 KVM Agent에서 확인한다. 지원 작업은 현재 Mold GFS2/file-qcow2와 L2 네트워크다. IPAM 네트워크는 원본 IP 예약을 지원하는 어댑터가 검증되기 전까지 사전 차단한다. 기존 v1 Linux·Windows DATA-only 계획은 자동 변환하지 않는다.

대상 첫 부팅 SYSTEM 작업은 실제 Mold NIC UUID/network UUID/MAC과 현재 guest 장치를 결합한다. PnP/link 준비를 기다린 후 대상 NIC만 변경한다. 동일 source GUID/PnP/IP의 non-present 이전 장치만 제한적으로 처리하며 다른 NIC의 IP 점유는 충돌로 중단한다. 전체 NIC 초기화나 전역 TCP/IP reset은 수행하지 않는다.

대상 설정은 WinRM/RDP 연결 없이 적용하고, 기존 QGA 파일 RPC로 관측한다. 원본 OFF 확인 후 같은 IP/MAC의 대상을 시작한다. 수동 IPv6, 팀/브리지/VLAN/VPN, 정책 DNS, 모호한 대응은 전용 검증 없이 평탄화하지 않는다. IPv6의 기본 자동 동작은 유지한다.

`complete=true`는 기존 preallocation/controller/DATA와 필요한 모든 Windows NIC의 주소·gateway·DNS가 실제 보고서에서 VERIFIED일 때만 기록한다. 정적 주소의 DAD Preferred와 지속 설정도 확인한다. 재부팅·호스트 이동 시 새 binding/boot scope로 읽기 전용 관측하며 이후 사용자가 바꾼 IP/DNS를 되돌리지 않는다. `off`와 기존 DATA-only 기록은 Windows 네트워크 복원 성공으로 표시하지 않는다.

반입 이후 계획 hash/helper를 교체하거나 관리 이미지를 오프라인 재개방하지 않는다. v2 canonical JSON은 자동 metric의 명시적인 null을 보존한다. 초기 저장 경로에서 누락된 null은 원래 SHA-256이 정확히 재현되는 경우에만 읽기 시 복원하며 정책이나 저장된 hash를 변경하지 않는다.

이전 NIC 제거가 3010(재부팅 필요)으로 끝나거나 비동기 IP 점유 해제가 지연되면, 종료 코드를 journal에 남기고 최대 1회만 제어된 게스트 재부팅을 수행한다. 재부팅 전에는 새 NIC의 IP를 변경하지 않는다. 새 guest boot와 새 binding challenge를 확인한 뒤 같은 계획으로 재개한다. 게스트 내부 재부팅은 QEMU PID가 같을 수 있으므로 Agent는 결합된 재부팅 요청에만 nonce를 한 번 갱신한다. 그 뒤에도 충돌이 남으면 자동 재부팅을 반복하지 않고 복구 필요로 중단한다.
