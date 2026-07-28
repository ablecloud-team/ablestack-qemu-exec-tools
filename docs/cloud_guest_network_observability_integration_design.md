# Cloud Guest Network Observability 연계 설계

## 문서 정보

- 상태: 구현 전 상세 설계
- 작성일: 2026-07-27
- 작업 브랜치: `codex/guest-network-observability-design`
- 대상: Rocky/RHEL/Alma/Ubuntu/Debian 게스트
- 연계 시스템: `ablestack-cloud` Guest Network Observability

이 문서는 `ablestack-qemu-exec-tools`가 QGA 전체 기능을 활성화하면서 Cloud의
IP/DNS/route 관측에 필요한 실제 게스트 준비 상태를 제공하는 방법을 정의한다.

## 1. 현재 구현과 결함

현재 `bin/agent_policy_fix.sh`:

- RHEL/Rocky/Alma/Oracle Linux에 QGA를 설치하고 `/etc/sysconfig/qemu-ga`를 변경한다.
- Ubuntu/Debian에 QGA를 설치하고 서비스만 확인한다.
- RHEL 계열에서는 vendor block 예시를 active allow 목록으로 병합한다.
- RPM `%post`, DEB `postinst`, ISO `install-linux.sh`를 통해 실행될 수 있다.

유지할 요구사항:

- 향후 파일 작업과 게스트 자동화를 위해 QGA 지원 RPC 전체를 허용한다.
- `guest-file-*`, 사용자/SSH key, exec RPC를 네트워크 수집만을 이유로 제거하지 않는다.

보완할 결함:

- `/bin/true` 실행만으로 실제 network command readiness를 판단한다.
- `virt_qemu_ga_t`의 `/usr/sbin/ip` 실행 거부를 탐지하거나 수정하지 않는다.
- Ubuntu/Debian은 실제 정책을 검사하지 않고 기본 허용으로 가정한다.
- 설정이 같아도 backup과 QGA restart를 반복한다.
- active 설정 parse가 vendor file 형식에 강하게 결합된다.
- policy apply 실패 rollback과 전용 자동 테스트가 없다.

## 2. 공개 CLI 계약

```text
agent_policy_fix --policy full --check [--json]
agent_policy_fix --policy full --apply [--json]
agent_policy_fix --check-profile cloud-network-observability [--json]
```

하위 호환:

- option 없이 `agent_policy_fix`를 실행하면 `--policy full --apply`와 동일하게 동작한다.
- 기존 bilingual text 출력은 유지한다.
- `--json`은 stdout에 JSON만 출력하고 진단은 stderr에 쓴다.

exit code:

| 코드 | 의미 |
|---|---|
| 0 | policy/profile 준비 완료 |
| 2 | 인자 또는 지원하지 않는 OS |
| 3 | 패키지/설정/의존 command 누락 |
| 4 | policy apply 또는 service restart 실패 |
| 5 | security policy 또는 실제 profile preflight 실패 |

## 3. 코드 구조

현재 단일 script를 다음 library로 분리한다.

```text
bin/agent_policy_fix.sh
lib/agent_policy/os_detect.sh
lib/agent_policy/package_manager.sh
lib/agent_policy/qga_config.sh
lib/agent_policy/qga_service.sh
lib/agent_policy/security_policy.sh
lib/agent_policy/profile_check.sh
lib/agent_policy/json_output.sh
bin/guest_network_snapshot.sh
selinux/ablestack_qga_observer.te
selinux/ablestack_qga_observer.if
selinux/ablestack_qga_observer.fc
apparmor/ablestack-qga-observer
```

`agent_policy_fix.sh`는 orchestration만 담당하며 설정 parse, package manager, policy
설치를 직접 구현하지 않는다.

## 4. OS 판별

```bash
detect_os() {
    # /etc/os-release의 ID, ID_LIKE, VERSION_ID를 JSON-safe 값으로 반환
}
```

분류:

- RPM: `rhel`, `rocky`, `centos`, `almalinux`, `ol`, `fedora` 또는 `ID_LIKE`에 rhel
- DEB: `ubuntu`, `debian` 또는 `ID_LIKE`에 debian

직접 `ID` 목록에 없는 호환 배포판은 `ID_LIKE`로 분류하되 결과에 판별 근거를 남긴다.

## 5. QGA 전체 RPC 정책

### 5.1 의미

`policyMode=FULL`은 설치된 QGA가 제공하고 runtime에서 활성화할 수 있는 command 전체를
allow하도록 설정했다는 의미다.

QGA build 자체에서 disabled된 command는 `runtimeDisabled`에 기록하고 FULL 실패로
처리하지 않는다.

### 5.2 desired state 계산

```bash
discover_qga_supported_rpcs
read_active_qga_policy
build_full_allow_policy
render_qga_policy
```

우선순위:

1. 설치된 `qemu-ga`가 제공하는 command 목록
2. active allow/block 설정
3. vendor config의 command 목록

주석 block 목록을 allow로 전환하는 기존 목적은 유지하되, 주석 목록만을 유일한
source로 사용하지 않는다.

### 5.3 idempotent apply

```text
desiredHash == activeHash
  -> write 0, backup 0, restart 0

desiredHash != activeHash
  -> backup -> atomic replace -> restart -> verify
  -> verify 실패 시 restore -> restart -> exit 4
```

임시 파일은 대상 config와 같은 filesystem에 생성하고 mode/owner를 보존한 뒤 atomic
rename한다. backup은 package가 관리하는 디렉터리에 제한된 개수만 보존한다.

### 5.4 배포판 설정 탐지

고정 경로를 가정하기 전에 다음을 확인한다.

- `systemctl cat qemu-guest-agent`
- `EnvironmentFile`
- active process arguments
- RHEL 계열 `/etc/sysconfig/qemu-ga`
- Debian 계열 `/etc/default/qemu-guest-agent` 등 실제 package config

## 6. readiness JSON

```json
{
  "schemaVersion": 1,
  "policyMode": "FULL",
  "os": {
    "id": "rocky",
    "idLike": ["rhel", "centos"],
    "version": "9.4"
  },
  "qga": {
    "installed": true,
    "active": true,
    "version": "8.2.0",
    "supportedRpcCount": 42,
    "policyEnabledRpcCount": 42,
    "runtimeDisabled": ["guest-get-devices"]
  },
  "profiles": {
    "cloud-network-observability": {
      "version": 1,
      "status": "READY",
      "checks": []
    }
  },
  "changed": false,
  "restartPerformed": false
}
```

guest 내부 config 검사 결과와 hypervisor가 보는 `guest-info` 결과는 다를 수 있다.
최종 runtime command 확인은 Cloud Agent preflight가 담당한다.

## 7. Guest Network Snapshot Helper

설치 경로:

```text
/usr/libexec/ablestack-qemu-exec-tools/guest-network-snapshot
```

CLI:

```text
guest-network-snapshot --schema 1 --sections addresses,routes,dns
```

지원 section:

- `addresses`
- `routes`
- `dns`

입력 제한:

- section은 위 enum의 comma-separated 조합만 허용
- 임의 command/path/shell expression 입력 없음
- environment로 command를 override하지 못하게 함

Linux 수집:

- address: `ip -j address show`
- route: `ip -j -4/-6 route show table all`
- DNS: `resolvectl`, `nmcli`, `/etc/resolv.conf`

Helper는 필요한 command의 absolute path를 내부에서 탐지하되 결과에 실제 source를
기록한다.

출력:

- 단일 bounded JSON
- schema/tool/profile/OS metadata
- section별 status/source/errorCode
- 전체 IP, prefix, primary/secondary flag
- IPv4/IPv6 route
- DNS server/search domain

Helper가 일부 section에 실패해도 parse 가능한 JSON을 반환하고 section status로
실패를 표현한다.

## 8. SELinux

### 8.1 정책 목표

- SELinux enforcing을 유지한다.
- `virt_qemu_ga_t`가 전용 Helper를 실행할 수 있게 한다.
- Helper가 network state를 읽는 데 필요한 권한만 허용한다.
- network 설정 변경, package 변경, 임의 파일 쓰기 권한을 Helper domain에 부여하지 않는다.

### 8.2 패키징

- policy source는 repository에서 review한다.
- RPM build 시 module을 생성한다.
- `%post`에서 version-aware install/upgrade한다.
- `%preun`/`%postun`은 package removal 종류를 구분해 module을 제거한다.
- runtime `audit2allow` 자동 생성은 금지한다.
- `setenforce 0`, broad `chcon`, executable을 `bin_t`로 바꾸는 방식은 금지한다.

### 8.3 검증

- enforcing 상태
- QGA context
- Helper 실행
- `ip` address/route
- DNS source
- AVC 신규 발생 여부

## 9. Ubuntu/Debian

- 기본 허용을 가정하지 않는다.
- service config와 active process arguments를 검사한다.
- Cloud Agent의 실제 `guest-info`/Helper 실행으로 최종 확인한다.
- AppArmor profile이 실행을 막으면 package-owned 좁은 rule로 보완한다.
- AppArmor 전체 disable은 금지한다.

## 10. package lifecycle

RPM:

- 게스트용 package/subpackage에 `qemu-guest-agent`, `iproute` 의존성 명시
- SELinux policy package 의존성은 해당 배포판 조건으로 추가
- `%post`는 FULL policy apply 후 profile check

DEB:

- 기존 `qemu-guest-agent` dependency 유지
- `iproute2` dependency 명시
- postinst는 idempotent apply/check

장기적으로 host 도구와 guest 준비 기능을 다음 subpackage로 분리한다.

```text
ablestack-qemu-exec-tools
ablestack-qemu-guest-observer
```

Cloud Helper와 security policy는 guest observer subpackage에 둔다.

## 11. 테스트

### 11.1 fixture

- Rocky 8/9
- RHEL 호환 `ID_LIKE`
- Ubuntu 20.04/22.04/24.04
- Debian 11/12
- allow config 있음/없음
- block config 있음/없음
- compile-disabled RPC 포함

### 11.2 smoke

- `bash -n`
- option parser
- FULL desired state
- unchanged no restart
- atomic rollback
- JSON schema
- Helper output limit
- SELinux enforcing Helper 실행

### 11.3 22.x gate

- 대상 Rocky VM에서 file read RPC와 Helper 성공
- Rocky 다중 IP primary/secondary
- IPv4/IPv6 route
- DNS source
- Ubuntu/Debian 표본 동일 gate

## 12. 구현 순서

1. script library 분리와 fixture test
2. FULL policy discovery/idempotent apply/rollback
3. Helper schema 및 parser test
4. SELinux/AppArmor source policy
5. RPM/DEB package lifecycle
6. ISO upgrade path
7. Cloud Agent 연계 preflight
8. 22.x OS matrix

## 13. 구현 및 22.x 파일럿 상태

설계 브랜치에서 다음을 구현했다.

- `agent_policy_fix.sh`의 OS/QGA/profile library 분리와 FULL policy apply/check
- 고정 read-only `guest-network-snapshot` Helper
- package-owned SELinux module source와 installer
- RPM/DEB lifecycle 반영
- OS/policy/Helper smoke test와 RPM build

smoke test와 RPM build가 통과했으며 파일럿 RPM은
`ablestack-qemu-exec-tools-0.9.3-1.el9.el9.noarch.rpm`이다. Host 2에 이 RPM을
설치했을 때 ABLESTACK host guard가 guest customization을 건너뛰었고
`mold-agent.service`는 정상 상태를 유지했다.

대상 Rocky 9.4 guest의 실제 preflight:

- QGA 8.2, guest-exec/file RPC enabled
- QGA context `virt_qemu_ga_t`
- interface 표준 RPC는 IPv4/IPv6를 정상 반환
- `/usr/sbin/ip`, RPM/DNF, `semodule` 실행은 permission denied
- `systemctl`은 D-Bus access denied
- Helper는 아직 미설치

이는 Host에 설치한 package가 guest filesystem을 변경하지 않는다는 책임 경계와
일치한다. 현재 QGA 권한으로 guest package를 안전하게 bootstrap할 수 없으므로
console, SSH, cloud-init 또는 image provisioning 중 하나의 privileged guest
경로로 observer package를 설치해야 한다. 비밀번호/shadow 변경, cron 삽입,
임의 guest-file write는 bootstrap 우회 수단으로 사용하지 않는다.

운영자가 대상 Rocky guest 내부에 RPM을 설치한 뒤 QGA
`virt_qemu_ga_t` context에서 Helper address/routes/DNS가 모두 `OK`,
profile이 `READY`로 반환됨을 확인했다. Cloud 재수집 결과도 aggregate `OK`,
readiness `READY`, IPv4/IPv6 route 12개와 DNS 서버 2개로 정상 전환됐다.

Helper의 package version은 현재 `unknown`이다. runtime `rpm -q`가 Helper
SELinux domain에서 제한되기 때문이다. 후속 구현에서는 package build 시
read-only version manifest를 함께 설치하고 Helper가 해당 파일을 읽도록 변경한다.
