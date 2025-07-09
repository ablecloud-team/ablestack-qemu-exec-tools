# ablestack-qemu-exec-tools

**QEMU / libvirt 기반의 가상머신에 대해 `qemu-guest-agent`를 활용하여 원격 명령 실행 및 출력 파싱을 자동화하는 도구입니다.**

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

---

## ⚙️ 설치 방법

```bash
git clone https://github.com/ablecloud-team/ablestack-qemu-exec-tools.git
cd ablestack-qemu-exec-tools
chmod +x install.sh
sudo ./install.sh
```

**⚠ 의존성:**  
본 도구는 `jq`와 `virsh`가 설치되어 있어야 합니다.

---

## 🚀 기본 사용법

```bash
vm_exec -l|-w|-d <vm-name> <command> [args...] [options]
```

- `-l` 또는 `--linux` : Linux VM (bash -c로 실행)
- `-w` 또는 `--windows` : Windows VM (cmd.exe /c로 실행)
- `-d` 또는 `--direct` : Windows에서 직접 실행파일 호출 (예: `tasklist.exe`)

---

## 🧪 사용 예제

### ▶ Linux VM: ps 출력 파싱

```bash
vm_exec -l ubuntu-vm ps aux --table --headers "USER,PID,%CPU,%MEM,COMMAND" --json
```

### ▶ Windows VM: tasklist 파싱

```bash
vm_exec -w win-vm tasklist --table --headers "Image Name,PID,Session Name,Session#,Mem Usage" --json
```

### ▶ 스크립트 파일 실행 (병렬 가능)

```bash
vm_exec -l centos-vm --file commands.txt --parallel
```

---

## 🧩 옵션 정리

| 옵션             | 설명 |
|------------------|------|
| `--json`         | 결과를 JSON 형식으로 출력 |
| `--csv`          | CSV 출력 파싱 |
| `--table`        | 표 형태 출력 파싱 |
| `--headers`      | `--table` 사용 시 고정폭 열 정의 (예: `"PID,COMMAND"` ) |
| `--out <file>`   | 출력 결과를 파일로 저장 |
| `--exit-code`    | 명령 종료 코드 출력 |
| `--file <file>`  | 각 줄마다 명령을 실행하는 스크립트 파일 실행 |
| `--parallel`     | 스크립트 파일 실행 시 병렬 처리 |

---

## 🧾 라이선스

본 프로젝트는 [Apache License 2.0](LICENSE)에 따라 제공됩니다.  
© 2025 ABLECLOUD
