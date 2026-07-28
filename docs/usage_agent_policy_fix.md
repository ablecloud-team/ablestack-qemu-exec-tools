
# agent_policy_fix 사용 설명서

## 개요

`agent_policy_fix.sh`는 리눅스 가상머신(RHEL/Rocky/Alma/Ubuntu/Debian 계열) 환경에서 `qemu-guest-agent`의 설치, 서비스 설정 그리고(RHEL 계열 특정) RPC 정책 자동화를 수행하는 도구입니다.

- **주요 목적:**
  1. `qemu-guest-agent` 패키지가 설치되어 있는지 확인, 자동 설치
  2. 서비스가 정상적으로 실행되고 있는지 확인, 자동 설정
  3. RHEL/Rocky/Alma 계열에서 `/etc/sysconfig/qemu-ga`의 정책 옵션(`allow-rpcs`)을 자동 조정
  4. Ubuntu/Debian 계열에서는 모든 정책을 기본 허용으로 유지

## Cloud 게스트 네트워크 관측 연계 설계

현재 버전의 `agent_policy_fix`는 QGA 패키지/서비스와 전체 RPC 허용 설정을
준비하지만, 다음 항목까지 성공했다고 보장하지는 않습니다.

- SELinux/AppArmor가 `/usr/sbin/ip` 등 실제 조회 명령 실행을 허용하는지
- IP 주·보조 역할, IPv4/IPv6 route, DNS를 모두 읽을 수 있는지
- `ablestack-qemu-exec-tools` 전용 네트워크 Helper가 설치되어 있는지

QGA 전체 RPC 허용 정책은 파일 관련 command를 포함한 향후 게스트 Agent 활용을 위해
유지합니다. 네트워크 관측 기능은 전체 RPC 정책 위에서 별도의 readiness profile로
검증하도록 설계합니다.

CLI 사용법과 상세 구현 계약은
`cloud_guest_network_observability_integration_design.md`를 기준으로 합니다.

```text
agent_policy_fix --policy full --check --json
agent_policy_fix --policy full --apply --json
agent_policy_fix --check-profile cloud-network-observability --json
```

위 option과 전용 Helper/SELinux 정책은 구현 및 패키징되었으며, 실제 게스트에서
route와 DNS를 수집하려면 해당 패키지를 게스트 운영체제 내부에 설치해야 합니다.

---

## 지원 환경

- Rocky Linux 8/9, RHEL 8/9, AlmaLinux 8/9 등(RHEL 계열)
- Ubuntu 20.04/22.04/24.04, Debian 10/11/12 등(Debian/Ubuntu 계열)

---

## 설치 및 실행

1. VM(게스트) 환경에 `agent_policy_fix.sh` 파일을 복사합니다.
2. root 또는 sudo 권한이 필요합니다.
3. 실행:

    ```bash
    sudo agent_policy_fix
    ```

   또는 파일 직접 실행

    ```bash
    sudo ./agent_policy_fix.sh
    ```

---

## 작동 방식

### [RHEL/Rocky/Alma 계열]

- `qemu-guest-agent` 설치 여부 확인, 자동 설치
- 서비스가 비활성화/비실행 상태이면 자동 enable+start
- `/etc/sysconfig/qemu-ga`에 FILTER_RPC_ARGS를 추가하여
  - allow-rpcs, block-rpcs 옵션 병합
  - guest-exec 등 모든 RPC 명령 전면 허용 정책으로 변경
- 서비스 재시작 후 정상 작동 확인

### [Ubuntu/Debian 계열]

- `qemu-guest-agent` 설치 여부 확인, 자동 설치
- 서비스가 비활성화/비실행 상태이면 자동 enable+start
- **?�책 ?�동???�요 ?�음:**
  - Ubuntu/Debian 계열?� qemu-guest-agent??모든 RPC 명령??기본 ?�용
  - 별도 ?�정/?�동???�이 바로 ?�용 가??

---

## 주요 ?�션 �??�자

- �??�크립트??**?�션?�나 ?�자 ?�이 ?�행**?�면 ??- 별도???�경?�정?�나 추�? ?�션 불필??

---

## ?�용 ?�제

### 1. 기본 ?�행

```bash
sudo agent_policy_fix
```

or

```bash
sudo ./agent_policy_fix.sh
```

### 2. ?�상 출력 ?�시

```
[INFO] Ubuntu/Debian 계열�?감�???
[INFO] qemu-guest-agent가 ?��? ?�치?�어 ?�습?�다.
[INFO] qemu-guest-agent ?�비?��? ?��? ?�성???�행) ?�태?�니??
[NOTICE] Ubuntu 계열?� qemu-guest-agent??모든 RPC 명령??기본?�으�??�용?�어 ?�습?�다.
         별도???�책 ?�정?�나 추�? ?�동???�업?� ?�요?��? ?�습?�다.
```

---

## ?�의?�항

- 반드??**게스??가?�머?? ?��?**?�서 ?�행?�야 ?�니??
- RHEL/Rocky 계열 ?�책 변�???`/etc/sysconfig/qemu-ga`가 백업?�니??
- ?�행??root 권한(?�는 sudo)???�요?�니??
- ?�책 ?�일 구조, ?�비?�명 ?�이 배포??버전???�라 ?��? ?��? ???�습?�다.

---

## ?�이?�스 �?문의

- Apache License 2.0
- 문의: ABLECLOUD ?�픈?�스 ?�로?�트 ?�이지 참고

---
