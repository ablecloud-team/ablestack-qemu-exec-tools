# v2k 게스트 설정 자동 복원

신규 Mold 파일/qcow2 이관의 `--guest-config-policy` 기본값은 `preserve`다. 원본 VMware Tools Guest Operations로 의도를 읽고, final copy가 끝난 비관리 복제본에 첫 부팅 작업과 오프라인 QGA를 준비한다. Mold가 실제 VM·볼륨·NIC와 결합하고 게스트의 현재 상태를 확인한 뒤 완료한다. VM의 `Running` 상태만으로 자동 복원을 완료하지 않는다.

## 지원 범위와 준비

v1 실기 자격 범위는 13번 GFS2, Ubuntu 22.04의 Netplan Ethernet/networkd, Windows Server 2022 build 20348의 basic 디스크다. source IDE/BIOS, SATA/EFI, SCSI/EFI를 포함한다. Ubuntu는 검증된 MAC에 원래 ifname을 연결하고 DHCP/정적 주소, routes/DNS/MTU를 보존한다. Windows는 DATA의 원본 GUID/파티션과 실제 대상 serial을 대조해 원래 online/read-only 상태와 드라이브 문자를 복원한다. 추가된 빈 CD-ROM의 문자 충돌만 제한적으로 해제하며 전역 SAN 정책은 변경하지 않는다.

복잡한 Netplan 토폴로지·인증 설정, 모호한 대응, 폴더 mount path 등 v1 어댑터가 지원하지 않는 구성은 추정하지 않고 차단한다. RBD/raw·직접 libvirt에는 이 자동 복원 어댑터를 적용하지 않는다. 해당 기존 흐름은 명시적 `--guest-config-policy off`로 실행한다.

호스트에는 guestfish, virt-customize, pyYAML, Windows 서비스 firstboot 실행기와 QGA MSI가 필요하다. Windows firstboot는 현재 자격 검증한 guestfs-tools 1.52.2 실행 경로로 제한한다. firstboot 보조 실행기는 배포판 virt-v2v 의존성으로 제공한다. RHEL 계열의 NTFS 제한을 피하기 위해 사설 경로에 upstream libguestfs/guestfish 1.58.1과 SHA-256을 고정한 appliance를 준비한다. 시스템 libguestfs와 기존 ISO는 교체하지 않는다. 네이티브 런타임을 포함하는 v2k RPM은 x86_64 패키지다.

Release CI는 `tools/v2k/prepare-guest-config-assets.py`로 서명된 Ubuntu InRelease/index와 DEB SHA를 검증하고, `prepare-guest-config-appliance.py`, `build-guest-config-native.sh`로 사설 런타임을 준비한다. Windows QGA MSI는 prepare-guest-config-windows.py로 버전/해시를 고정해 준비한다. 큰 appliance는 원본 압축 archive로 RPM에 넣고, SHA 검증 후 사설 캐시에 sparse 파일을 유지하며 푼다. 새 payload와 라이선스/출처 메타데이터는 RPM에 포함한다. 대상 게스트에서 인터넷 다운로드를 요구하지 않는다. 개발 검증용 자산 경로는 `V2K_GUEST_CONFIG_UBUNTU_ASSETS`, `V2K_GUEST_CONFIG_APPLIANCE`, `V2K_GUEST_CONFIG_NATIVE`, `V2K_GUEST_CONFIG_VIRTIO_ROOT`로 지정한다.

## CLI와 Wizard

| 옵션 | 동작 |
|---|---|
| `--guest-config-policy preserve\|off` | 신규 지원 작업의 기본값 preserve. off는 자동 복원 미검증으로 표시한다. |
| `--source-guest-user` | vCenter 계정과 별도인 원본 게스트 관리자 계정 |
| `--source-guest-password-fd` | 실행 시 보호된 FD에서 비밀번호를 한 번 읽는다. |
| `--guest-config-map-json` | 인증 정보가 없는 명시적 원본 상태 JSON. 수집 probe와 같은 스키마·식별자 검증을 받는다. |
| `--guest-config-timeout` | 게스트 관측 deadline, 기본 600초, 최대 1800초 |

Wizard는 TTY에서 정책과 원본 게스트 인증을 요청한다. 실행 중 읽기 전용 원본 수집 결과와 Netplan 변경 diff/Windows DATA 의도를 후보로 표시하며, 실제 디스크 대응은 final clone에서 확인해 고정한다. `--yes` 실행은 런타임 인증 또는 명시적 상태 JSON이 없으면 원본 종료 전에 중단한다. `--print-command`는 게스트 probe와 복제본 변경을 수행하지 않으며 게스트 비밀번호 FD도 소비하지 않는다. 비밀번호를 CLI 인자로 넣거나 파일에 저장하지 않는다. 런타임 환경 변수 `V2K_SOURCE_GUEST_USER`, `V2K_SOURCE_GUEST_PASSWORD`도 사용할 수 있다.

```bash
read -r -p 'Source guest user: ' V2K_SOURCE_GUEST_USER
read -r -s -p 'Source guest password: ' V2K_SOURCE_GUEST_PASSWORD
export V2K_SOURCE_GUEST_USER V2K_SOURCE_GUEST_PASSWORD
# 기존 vCenter/Mold 런타임 인증과 대상 리소스 옵션을 함께 지정한다.
ablestack_v2k wizard --vm test-vm --target-profile cloud-filesystem \
  --guest-config-policy preserve --split full
unset V2K_SOURCE_GUEST_PASSWORD
```

## 결합, 재시도와 완료

Mold의 Root admin API `getMigrationGuestConfigurationCapabilities`는 실제 worker의 기능을 확인한다. `reconcileMigratedGuestConfiguration`은 VM ID·계획 해시·operation ID만 받으며 임의 명령/파일 경로를 실행하지 않는다. 고정된 QGA file RPC 경로에서 64 KiB 이내의 binding/commit/report를 전달한다. 계획·결합·마지막 검증은 기존 숨김 metadata에 저장하며 새 DB 테이블/컬럼은 없다.

요청의 확인값과 완전한 파일의 길이/SHA를 대조한다. 마지막에 이미 소비한 보고서는 새 관측으로 인정하지 않는다. VM UUID·ROOT 식별자·볼륨/NIC·현재 QEMU 실행과 일치하는 새 보고서가 필요하다. 이 해시는 게스트 관리자에 대한 보안 attestation을 의미하지 않는다.

Windows는 QGA 시작 전에 전용 파일의 SYSTEM/Administrators ACL을 명시하고, 한 개의 firstboot 항목에서 MSI와 SYSTEM startup 작업을 준비한다. 첫 부팅 재부팅 뒤 해당 작업이 실행된다. 시간 보정과 무관한 제한 시간을 사용하고, 완료 후에는 상시 읽기 전용 관측만 수행한다. 변경은 write-ahead journal에 기록한다. 부분 실패의 보상은 현재 상태가 마지막 소유 변경값과 일치할 때만 한 번 수행하고, 충돌 시 멈춘다. VERIFIED 후 DATA를 다시 조정하지 않는다. 이후 관측은 읽기 전용이며 사용자 변경을 되돌리지 않는다.

Ubuntu는 복제본의 기존 Netplan을 수정·백업하고 cloud-init의 네트워크 생성만 비활성화한다. 호스트에서 netplan apply를 실행하지 않는다. 게스트 도구로 generate를 검증한다. 첫 부팅 검증과 binding 파일 감시가 실제 MAC/ifname·주소·설정을 읽는다.

`preserve`는 필요한 게스트 항목이 VERIFIED일 때만 `complete=true`가 된다. define-only는 STAGED/BOUND, 명시적 off는 SKIPPED로 구분한다. 구형 계획 없는 manifest의 기존 이관 완료 이력은 유지하되 `LEGACY_UNVERIFIED`와 `guest_configuration_verified=false`를 표시한다. 기존 완료 이력을 새 자동 복원 성공으로 해석하지 않는다.

반입 요청 UUID가 생긴 뒤에는 원본 재복사·guestfs 주입을 수행하지 않는다. 실패 대상은 자동 폐기하지 않으며 동일 operation을 API로 재조회한다. helper가 없는 기존 반입 VM은 새 이관이 필요하다. SOURCE_CONFIG_REQUIRED, NIC_MAPPING_AMBIGUOUS, DATA_IDENTITY_MISMATCH, ACCESS_PATH_CONFLICT, FIRSTBOOT_CAPABILITY_MISSING, GUEST_CHANNEL_UNAVAILABLE, GUEST_CONFIG_TIMEOUT을 구분해 확인한다.
