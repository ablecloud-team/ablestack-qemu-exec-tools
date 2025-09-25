# ablestack-qemu-exec-tools

**QEMU / libvirt 기반 가상머신에 대해 `qemu-guest-agent`를 활용, 원격 명령 실행과 정책 자동화를 지원하는 도구입니다.**

---

## 📌 주요 기능

- VM 내부 명령 실행 지원 (Linux, Windows)
- `virsh qemu-agent-command`를 통한 비침입 원격 제어
- 다양한 출력 파싱 옵션 지원:
  - `--json`: 전체 결과를 JSON 형식으로 출력
  - `--table`: 테이블 형태 출력 파싱
  - `--headers`: 고정폭 테이블 해석을 위한 명시적 헤더 지정
  - `--csv`: CSV 출력 파싱
- 스크립트 파일 실행 (`--file`) 및 병렬 실행 (`--parallel`) 지원
- **agent_policy_fix.sh**: 게스트(VM) 내부에서 qemu-guest-agent의 정책 자동화(RHEL 계열), 서비스 자동 활성화, 자동 설치 지원 (Ubuntu 계열 완전 허용 안내)

---

## ⚙️ 설치 방법

```bash
git clone https://github.com/ablecloud-team/ablestack-qemu-exec-tools.git
cd ablestack-qemu-exec-tools
chmod +x install.sh
sudo ./install.sh
```

**⚠ 의존성:**  
`jq`와 `virsh(libvirt-clients)` 패키지가 사전에 설치되어 있어야 합니다.

---

## 🏗️ 패키지 빌드 및 배포

이 프로젝트는 **RPM (RHEL 계열), DEB (Ubuntu 계열), MSI (Windows)** 패키지를 공식 지원합니다.  
모든 빌드 및 릴리즈 과정은 **GitHub Actions**를 통해 자동화되어 있습니다.

### 로컬 빌드 (옵션)
- **RPM 빌드**
  ```bash
  make rpm
  ls rpmbuild/RPMS/*/*.rpm
  ```
- **DEB 빌드**
  ```bash
  make deb
  ls build/deb/*.deb
  ```
- **MSI 빌드 (Windows)**
  ```powershell
  make windows
  Get-ChildItem windows/msi/out/*.msi
  ```

### GitHub Actions
- **ci.yml** → 브랜치 push/PR 시 기본 빌드 검증  
- **build.yml** → 태그 push 시 RPM/DEB/MSI 빌드 후 GitHub Release 업로드  

**👉 상세한 절차는 [INSTALL.md](INSTALL.md) 및 [RELEASE_WORKFLOW.md](RELEASE_WORKFLOW.md)를 참고하세요.**

---

## 🚀 기본 사용법

### VM 명령 실행 (vm_exec)
```bash
vm_exec -l|-w|-d <vm-name> <command> [args...] [options]
```
- `-l` 또는 `--linux` : Linux VM (bash -c로 실행)
- `-w` 또는 `--windows` : Windows VM (cmd /c로 실행)
- `-d` 또는 `--dry-run` : 실제 명령 전송 없이 커맨드 빌드만 확인

### 에이전트 정책 자동화 (agent_policy_fix)
```bash
sudo agent_policy_fix
# 또는
sudo ./agent_policy_fix.sh
```
- RHEL/Rocky/Alma 계열: qemu-guest-agent 정책 자동화 및 서비스 활성화
- Ubuntu/Debian 계열: 자동 설치 및 서비스 활성화 (정책 자동화는 필요 없음)

---

## 📚 추가 문서

- [docs/usage_vm_exec.md](docs/usage_vm_exec.md) — VM 명령 실행 사용법
- [usage_agent_policy_fix.md](usage_agent_policy_fix.md) — 에이전트 정책 자동화 사용법
- [examples/](examples/) — 활용 예시
- [INSTALL.md](INSTALL.md) — 설치 및 배포 가이드
- [RELEASE_WORKFLOW.md](RELEASE_WORKFLOW.md) — 릴리즈 브랜치 전략 및 배포 절차

---

## 💬 유의사항

- VM 명령 실행 및 정책 자동화는 **root 또는 sudo 권한**이 필요할 수 있습니다.
- agent_policy_fix.sh는 반드시 **게스트(가상머신) 내부**에서 실행해야 합니다.
- 최신 기능/환경은 사용법 문서를 참고해 주세요.

---

## 📄 라이선스

Apache License 2.0  
Copyright (c) 2025 ABLECLOUD

---

## 📨 문의

- GitHub Issues 또는 ABLECLOUD 공식 채널
