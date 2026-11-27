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
