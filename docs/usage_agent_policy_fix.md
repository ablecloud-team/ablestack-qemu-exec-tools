
# agent_policy_fix 사용 설명서

## 개요

`agent_policy_fix.sh`는 리눅스 가상머신(RHEL/Rocky/Alma/Ubuntu/Debian 계열) 내부에서 `qemu-guest-agent`의 설치, 서비스 활성화, 그리고 (RHEL 계열 한정) RPC 정책 자동화 작업을 수행하는 도구입니다.

- **주요 목적:**  
  1. `qemu-guest-agent` 패키지가 설치되어 있는지 확인, 자동 설치  
  2. 서비스가 활성화되어 있지 않으면 자동 활성화  
  3. RHEL/Rocky/Alma 계열에서는 `/etc/sysconfig/qemu-ga`의 정책 옵션(`allow-rpcs`)을 자동 조정  
  4. Ubuntu/Debian 계열에서는 모든 정책이 기본 허용임을 안내

---

## 지원 환경

- Rocky Linux 8/9, RHEL 8/9, AlmaLinux 8/9 등 (RHEL 계열)
- Ubuntu 20.04/22.04/24.04, Debian 10/11/12 등 (Debian/Ubuntu 계열)

---

## 설치 및 실행

1. VM(게스트) 내부에 `agent_policy_fix.sh` 파일이 있어야 합니다.
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

## 동작 방식

### [RHEL/Rocky/Alma 계열]

- `qemu-guest-agent` 설치 여부 확인, 자동 설치
- 서비스가 비활성화/비실행 상태면 자동 enable+start
- `/etc/sysconfig/qemu-ga`의 FILTER_RPC_ARGS를 읽어
  - allow-rpcs, block-rpcs 옵션 병합
  - guest-exec 등 모든 RPC 명령 완전 허용 정책으로 변환
- 서비스 재시작 및 정상 동작 확인

### [Ubuntu/Debian 계열]

- `qemu-guest-agent` 설치 여부 확인, 자동 설치
- 서비스가 비활성화/비실행 상태면 자동 enable+start
- **정책 자동화 필요 없음:**
  - Ubuntu/Debian 계열은 qemu-guest-agent의 모든 RPC 명령이 기본 허용
  - 별도 설정/자동화 없이 바로 사용 가능

---

## 주요 옵션 및 인자

- 본 스크립트는 **옵션이나 인자 없이 실행**하면 됨
- 별도의 환경설정이나 추가 옵션 불필요

---

## 사용 예제

### 1. 기본 실행

```bash
sudo agent_policy_fix
```
or
```bash
sudo ./agent_policy_fix.sh
```

### 2. 예상 출력 예시

```
[INFO] Ubuntu/Debian 계열로 감지됨.
[INFO] qemu-guest-agent가 이미 설치되어 있습니다.
[INFO] qemu-guest-agent 서비스가 이미 활성화(실행) 상태입니다.
[NOTICE] Ubuntu 계열은 qemu-guest-agent의 모든 RPC 명령이 기본적으로 허용되어 있습니다.
         별도의 정책 설정이나 추가 자동화 작업은 필요하지 않습니다.
```

---

## 유의사항

- 반드시 **게스트(가상머신) 내부**에서 실행해야 합니다.
- RHEL/Rocky 계열 정책 변경 시 `/etc/sysconfig/qemu-ga`가 백업됩니다.
- 실행에 root 권한(또는 sudo)이 필요합니다.
- 정책 파일 구조, 서비스명 등이 배포판/버전에 따라 일부 다를 수 있습니다.

---

## 라이선스 및 문의

- Apache License 2.0
- 문의: ABLECLOUD 오픈소스 프로젝트 페이지 참고

---
