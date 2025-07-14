# vm_exec 사용법 (ablestack-qemu-exec-tools)

QEMU/libvirt 기반 VM 내부에서 명령을 원격으로 실행하고 결과를 파싱하는 도구입니다.  
qemu-guest-agent를 사용하는 `virsh qemu-agent-command`를 기반으로 작동합니다.

---

## 🧰 기본 실행 형식

```bash
vm_exec -l|-w|-d <vm-name> <command> [args...] [options]
```

### ▶ 실행 모드
| 옵션      | 설명                                      |
|-----------|-------------------------------------------|
| `-l`      | Linux VM (명령: `bash -c`)                |
| `-w`      | Windows VM (명령: `cmd.exe /c`)           |
| `-d`      | Windows Direct 실행 (예: `tasklist.exe`)  |

---

## ⚙️ 주요 옵션

| 옵션               | 설명                                                         |
|--------------------|--------------------------------------------------------------|
| `--json`           | 전체 실행 결과를 JSON 형식으로 출력                          |
| `--csv`            | CSV 형식의 결과를 파싱하여 JSON 변환                         |
| `--table`          | 텍스트 테이블을 파싱하여 JSON으로 출력                       |
| `--headers "..."`  | 고정폭 열 구분을 위한 명시적 헤더 지정 (CSV 아님, `--table`과 함께 사용) |
| `--out <file>`     | 명령 결과를 지정된 파일에 저장                                |
| `--exit-code`      | guest-exec의 종료 코드 출력                                  |
| `--file <file>`    | 스크립트 파일의 각 줄을 명령으로 실행                        |
| `--parallel`       | 스크립트 파일 실행 시 명령들을 병렬로 실행                   |

---

## 🔍 사용 예시

### ▶ Linux VM에서 `ps aux` 실행 후 JSON으로 출력

```bash
vm_exec -l ubuntu-vm ps aux --table --headers "USER,PID,%CPU,%MEM,COMMAND" --json
```

### ▶ Windows VM에서 `tasklist` 결과 JSON 파싱

```bash
vm_exec -w win10-vm tasklist --table --headers "Image Name,PID,Session Name,Session#,Mem Usage" --json
```

### ▶ CSV 결과(JSON 변환 포함)

```bash
vm_exec -d win-vm type perf.csv --csv --json
```

---

## 🗂 스크립트 파일 실행

```bash
vm_exec -l test-vm --file ./cmds.txt
```

cmds.txt 예시:

```
df -h
uptime
ps aux
```

#### 병렬 실행 (모든 명령을 동시에 실행):

```bash
vm_exec -l test-vm --file ./cmds.txt --parallel
```

---

## 🧪 출력 결과 예시

### ▶ JSON 출력 (예시):

```json
{
  "command": "-l ps aux",
  "parsed": [
    {
      "USER": "root",
      "PID": "1",
      "%CPU": "0.0",
      "%MEM": "0.1",
      "COMMAND": "/sbin/init"
    }
  ],
  "stdout_raw": "...",
  "stderr": "",
  "exit_code": 0
}
```

---

## ⚠️ 주의사항

- guest VM 내부에 `qemu-guest-agent`가 실행 중이어야 합니다.
- `virsh qemu-agent-command`는 VM이 실행 중이며 libvirt에서 접근 가능한 상태여야 작동합니다.
- Windows 명령어 실행 시, 경로/권한 이슈로 인해 직접 실행(`-d`) 방식이 더 안정적인 경우가 있습니다.

---

## 🧾 관련 파일

- `vm_exec.sh`: 실행 스크립트
- `parse_linux_table.sh`, `parse_windows_table.sh`: 테이블 파싱
- `common.sh`: 공통 함수 모음
