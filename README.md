# ablestack-qemu-exec-tools

**QEMU / libvirt 기반 가상머신에 대해 `qemu-guest-agent` 와 libguestfs 기반 도구를 활용하여, 비대화형 명령 실행·에이전트 자동화·자동 설치 지원하는 통합 관리 툴입니다.**

---

## 🚀 주요 기능

- **VM 내부 명령 실행** (Linux / Windows)
  - `virsh qemu-agent-command` 기반 비침투적 도구
  - JSON, CSV, TABLE, HEADERS 기반 출력 파싱
  - 스크립트 실행(`--file`) 과 병렬 실행(`--parallel`) 지원
- **에이전트 정책 자동화(`agent_policy_fix.sh`)**
  - VM 부팅 시 qemu-guest-agent 서비스 정책 자동화 생성 및 적용
- **클라우드 초기화 자동화(`cloud_init_auto.sh`)**
  - VM 생성 시 cloud-init 구동 구성 보조
- **자동 설치 기능 (`vm_autoinstall.sh`)** ⭐
  > 호스트에서 실행 중인 가상머신에 ISO를 자동 연결하고, OS에 맞는 설치 스크립트를 무인으로 실행
  > (vCenter에서 제공하는 자동 설치 기능의 오픈소스 클론 버전)

---

## ⚙️ 설치 방법

```bash
git clone https://github.com/ablecloud-team/ablestack-qemu-exec-tools.git
cd ablestack-qemu-exec-tools
chmod +x install.sh
sudo ./install.sh
```

### 호스트 시스템에 다음 패키지가 설치되어 있어야 합니다

| 구분 | 패키지 | 설명 |
|------|------|------|
| 기본 | `jq`, `virsh` | libvirt 기반 명령 도구 |
| 오프라인 주입 | `libguestfs-tools`, `virt-install` | virt-copy-in, virt-win-reg 필요 |
| 선택 | `virt-xml` | XML 조작 편의성 향상 |

---

## 📁 구성 파일 구조

```
bin/
 ├── vm_exec.sh
 ├── agent_policy_fix.sh
 ├── cloud_init_auto.sh
 ├── vm_autoinstall.sh       # 자동 ISO 연결 설치 스크립트
lib/
 ├── libvirt_helpers.sh      # libvirt 와 guestfs 헬퍼 함수
 ├── offline_inject_linux.sh # 오프라인 주입 (Linux)
 ├── offline_inject_windows.sh # 오프라인 주입 (Windows)
payload/
 ├── linux/ablestack-install.service   # ISO 루트 install-linux.sh 실행용 systemd unit
 ├── windows/ablestack-runonce.ps1     # ISO 루트 install.bat 자동 실행용 PowerShell
```

---

## 📖 주요 사용법
### 1. VM 명령 실행 (vm_exec)
```bash
vm_exec -l|-w <vm-name> "<command>"
```
- `-l` 또는 `--linux` : Linux VM
- `-w` 또는 `--windows` : Windows VM
- `--headers`, `--json`, `--table`, `--csv` 파싱 옵션 제공
- `--file <script>` : 외부 스크립트 실행
- `--parallel` : 병렬 실행

---

### 2. 에이전트 정책 자동화(agent_policy_fix)
```bash
sudo agent_policy_fix
```
- RHEL/Rocky 계열: 서비스 정책 생성 및 적용
- Ubuntu/Debian: qemu-guest-agent 자동 설치 및 설정

---

### 3. 가상머신 자동 설치 (vm_autoinstall) ⭐

```bash
sudo vm_autoinstall <vm-name> [--force-offline] [--no-reboot]
```

#### 🔄 작업 개요
| 상황 | 작업 |
|------|------|
| QGA(게스트 에이전트) 정상 | 무중단 온라인 설치 (게스트 내부 명령 직접 실행) |
| QGA 비정상 | VM 종료 후 스냅샷 찍기 + 오프라인 주입 + 부팅 자동 설치 |
| Transient VM | 임시로 XML 스냅샷 virsh create 시키기 |
| Persistent VM | virsh start 시키기 |
| 설치 완료 | ISO 연결 분리 (detach_iso_safely 함수 사용) |

#### ⚠️ 사전조건
- 호스트에 ISO 존재:
  `/usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso`
- ISO 루트에 스크립트 존재:
  - Windows 용 `install.bat`
  - Linux 용 `install-linux.sh`

#### 💡 예시
```bash
sudo vm_autoinstall win11-test
sudo vm_autoinstall rhel9-guest --force-offline
```

---

## 📦 ISO 작업 및 레벨 규칙

GitHub Actions(`build.yml`)에서 자동 생성:
```bash
mkisofs -o ablestack-qemu-exec-tools-${VERSION}.iso   -V "ABLESTACK"   -r -J release
```

> ISO 루트에는 `install.bat`, `install-linux.sh` 파일이 반드시 존재해야 하며,  
> Windows는 `install.bat`, Linux는 `install-linux.sh`를 실행하여 구동 시 설치합니다.

---

## 📁 설치 구성 정보

| 구성 | 경로 |
|------|------|
| 실행 파일 | `/usr/local/bin/` |
| 라이브러리 | `/usr/local/lib/ablestack-qemu-exec-tools/` |
| payload (주입 리소스) | `/usr/local/lib/ablestack-qemu-exec-tools/payload/` |
| ISO 기본 경로 | `/usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso` |
| 환경 변수 | `/etc/profile.d/ablestack-qemu-exec-tools.sh` |

---

## 🔧 동작 로직 요약

1. **QGA 감지**
   - `virsh qemu-agent-command <domain> '{"execute":"guest-ping"}'`
2. **온라인 모드**
   - 게스트 내부에서 ISO 마운트 후 `/install-linux.sh` 또는 `install.bat` 실행
3. **오프라인 모드**
   - `virt-copy-in`, `virt-customize`, `virt-win-reg` 명령으로 주입
   - 부팅 시 ISO 자동 마운트 후 루트 설치 스크립트 실행
   - `ablestack-install.service` / `ablestack-runonce.ps1` 사용
4. **CD-ROM 관리**
   - XML 조작(`inject_cdrom_into_xml`)으로 안전하게 ISO 연결
   - 설치 완료 시 `detach_iso_safely`로 ISO 제거

---

## 🐛 트러블슈팅
| 증상 | 원인 / 해결 |
|------|--------------|
| `virt-*` 명령 실패 | 루트 권한 또는 `LIBGUESTFS_BACKEND=direct` 환경 필요 |
| ISO 연결 분리 실패 | `virt-xml` 미설치 시 수동 `virsh detach-disk` 실행 가능 |
| QGA 응답 없음 | 오프라인 주입 모드로 자동 전환 |
| Transient VM 온라인 | XML 임시 스냅샷 `virsh create`로 복원 |

---

## 📄 라이선스

Apache License 2.0
Copyright (c) 2025 ABLECLOUD

---

## 📞 문의

- GitHub Issues 또는 ABLECLOUD 공식 채널
