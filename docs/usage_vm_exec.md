# vm_exec 사용법 (ablestack-qemu-exec-tools)

QEMU/libvirt 기반 VM 환경에서 명령을 게스트에서 실행하고 결과를 파싱하는 도구입니다.
qemu-guest-agent를 사용하는 `virsh qemu-agent-command`에 기반으로 작동합니다.

---

## 📋 기본 실행 형식

```bash
vm_exec -l|-w|-d <vm-name> <command> [args...] [options]
```

### 실행 모드
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
| `--csv`            | CSV 형식으로 결과를 파싱하여 JSON 변환                       |
| `--table`          | 테이블을 파싱하여 JSON으로 출력                              |
| `--headers "..."`  | 고정된 구분자를 가진 명시적 헤더 지정(CSV 파싱, `--table`과 함께 사용) |
| `--out <file>`     | 명령 결과를 지정된 파일에 저장                               |
| `--exit-code`      | guest-exec의 종료 코드 출력                                  |
| `--file <file>`    | 스크립트 파일의 각 줄을 명령으로 실행                        |
| `--parallel`       | 스크립트 파일 실행 시 명령들을 병렬로 실행                   |

---

## 💡 사용 예시

### 🐧 Linux VM에서 `ps aux` 실행 및 JSON으로 출력

```bash
vm_exec -l ubuntu-vm ps aux --table --headers "USER,PID,%CPU,%MEM,COMMAND" --json
```

### 🪟 Windows VM에서 `tasklist` 결과 JSON 파싱

```bash
vm_exec -w win10-vm tasklist --table --headers "Image Name,PID,Session Name,Session#,Mem Usage" --json
```

### ??CSV 결과(JSON 변???�함)

```bash
vm_exec -d win-vm type perf.csv --csv --json
```

---

## ?�� ?�크립트 ?�일 ?�행

```bash
vm_exec -l test-vm --file ./cmds.txt
```

cmds.txt ?�시:

```
df -h
uptime
ps aux
```

#### 병렬 ?�행 (모든 명령???�시???�행):

```bash
vm_exec -l test-vm --file ./cmds.txt --parallel
```

---

## ?�� 출력 결과 ?�시

### ??JSON 출력 (?�시):

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

## ?�️ 주의?�항

- guest VM ?��???`qemu-guest-agent`가 ?�행 중이?�야 ?�니??
- `virsh qemu-agent-command`??VM???�행 중이�?libvirt?�서 ?�근 가?�한 ?�태?�야 ?�동?�니??
- Windows 명령???�행 ?? 경로/권한 ?�슈�??�해 직접 ?�행(`-d`) 방식?????�정?�인 경우가 ?�습?�다.

---

## ?�� 관???�일

- `vm_exec.sh`: ?�행 ?�크립트
- `parse_linux_table.sh`, `parse_windows_table.sh`: ?�이�??�싱
- `common.sh`: 공통 ?�수 모음
