# vm_autoinstall 사용법 (ablestack-qemu-exec-tools)

호스트에서 실행 중인 QEMU/libvirt 기반 가상머신에  
**자동으로 ISO를 연결하고, 게스트 OS에 맞게 설치 스크립트를 실행하는 도구**입니다.  

vCenter의 “에이전트 자동 설치” 기능처럼, **한 번의 명령으로**  
Windows 및 Linux 게스트에 ablestack-qemu-exec-tools를 설치할 수 있습니다.

---

## 🧰 기본 실행 형식

```bash
vm_autoinstall <vm-name> [--force-offline] [--no-reboot]
```

---

## ⚙️ 주요 동작 모드

| 모드 | 조건 | 동작 방식 |
|------|------|-----------|
| **온라인 설치 모드** | 게스트에 `qemu-guest-agent`(QGA)가 실행 중 | VM을 중단하지 않고, 게스트 내부에서 ISO 마운트 후 설치 스크립트(`install-linux.sh` 또는 `install.bat`) 실행 |
| **오프라인 설치 모드** | QGA가 없거나 `--force-offline` 지정 | VM 종료 후 디스크 이미지에 1회 실행 훅 주입 → 부팅 시 자동으로 ISO 마운트 후 설치 |
| **Transient VM 지원** | VM이 종료되면 libvirt 목록에서 사라지는 경우 | 종료 직전 XML 및 디스크 정보 백업 → 주입 후 `virsh create`로 재기동 |
| **Persistent VM** | libvirt에 영구 등록된 VM | 오프라인 주입 후 `virsh start`로 재기동 |

---

## 🧩 옵션

| 옵션 | 설명 |
|------|------|
| `--force-offline` | QGA가 있더라도 강제로 오프라인 설치 절차를 수행 |
| `--no-reboot` | 오프라인 모드에서 VM을 주입만 하고 자동 부팅하지 않음 |
| `-h`, `--help` | 사용법 출력 |

---

## 🪶 동작 개요

1. **ISO 연결**
   - `/usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso` 를 VM CD-ROM 장치에 연결  
   - 기존 ISO가 연결된 경우 자동으로 새 슬롯 추가 또는 안전한 교체 수행
2. **QGA 감지**
   - `virsh qemu-agent-command <vm> '{"execute":"guest-ping"}'` 를 통해 확인
3. **온라인 설치 (QGA 있음)**
   - 게스트 내부에서 ISO 마운트 후:
     - Linux: `/install-linux.sh`
     - Windows: `/install.bat`
   - 실행 완료 후 ISO 자동 분리
4. **오프라인 설치 (QGA 없음)**
   - VM을 종료하고, 게스트 이미지에 다음 항목을 주입:
     - Linux: `ablestack-install.service` (systemd unit)
     - Windows: `ablestack-runonce.ps1` (RunOnce 등록)
   - 부팅 시 ISO 자동 마운트 후 설치 스크립트 실행
5. **재기동 및 검증**
   - VM 자동 기동 (또는 `--no-reboot`일 경우 수동 부팅)
   - 설치 완료 후 ISO 자동 제거 (`detach_iso_safely`)

---

## 🔧 전제 조건

| 항목 | 설명 |
|------|------|
| ISO 파일 | `/usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso` |
| ISO 라벨 | `"ABLESTACK"` (GitHub Actions에서 자동 지정됨) |
| ISO 루트 스크립트 | Windows → `install.bat` / Linux → `install-linux.sh` |
| 호스트 패키지 | `jq`, `virsh`, `libguestfs-tools`, `virt-install`, `virt-xml`(선택) |

---

## 💡 사용 예시

### ▶ 기본 사용 (QGA 감지 자동)
```bash
sudo vm_autoinstall my-vm
```
> QGA가 있으면 온라인 모드, 없으면 오프라인 모드로 자동 전환됩니다.

### ▶ QGA가 없을 때 강제로 오프라인 모드로 주입
```bash
sudo vm_autoinstall centos9-vm --force-offline
```

### ▶ 오프라인 주입만 하고 재부팅은 나중에
```bash
sudo vm_autoinstall win11-vm --force-offline --no-reboot
```
이후 수동으로 `virsh start win11-vm`을 수행하면 설치가 자동 진행됩니다.

---

## 🧾 출력 예시

```
[INFO] Attaching ISO /usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso
[INFO] QGA 감지됨 → 온라인 설치 경로
[OK] Linux 게스트 온라인 설치 완료
[OK] ISO 자동 분리 완료
```

또는 오프라인 모드의 경우:
```
[INFO] 오프라인 설치 경로 진입
[OK] Linux 오프라인 주입 완료
[OK] virsh create 실행 (Transient 부팅)
```

---

## 🧠 작동 원리 요약

1. `libvirt_helpers.sh`의 `inject_cdrom_into_xml()`로 ISO 안전 연결  
2. `has_qga()` → QGA 상태 판단  
3. 온라인 모드: `vm_exec.sh`를 통해 게스트 내부에서 설치 스크립트 실행  
4. 오프라인 모드:  
   - `offline_inject_linux.sh` / `offline_inject_windows.sh` 사용  
   - systemd unit 또는 RunOnce를 디스크 이미지에 주입  
   - 부팅 시 ISO 자동 마운트 후 설치 진행  
5. 설치 완료 후 `detach_iso_safely()`로 ISO 해제

---

## ⚠️ 주의사항

- 오프라인 모드에서는 VM이 **잠시 중단**됩니다.  
- `virt-*` 명령은 루트 권한이 필요하며, 일부 환경에서는 `LIBGUESTFS_BACKEND=direct` 설정이 필요할 수 있습니다.  
- ISO 파일이 없거나 손상된 경우 자동 주입이 실패합니다.  
- `install.bat` / `install-linux.sh`는 ISO 루트에 반드시 존재해야 합니다.

---

## 🗂 관련 파일

| 파일 | 설명 |
|------|------|
| `bin/vm_autoinstall.sh` | 메인 실행 스크립트 |
| `lib/libvirt_helpers.sh` | ISO 연결, QGA 체크, XML 조작 함수 |
| `lib/offline_inject_linux.sh` | Linux 오프라인 설치 주입 로직 |
| `lib/offline_inject_windows.sh` | Windows 오프라인 설치 주입 로직 |
| `payload/linux/ablestack-install.service` | Linux 부팅 후 install-linux.sh 실행용 systemd unit |
| `payload/windows/ablestack-runonce.ps1` | Windows 부팅 후 install.bat 실행용 PowerShell |

---

## 🧾 참고

- `vm_autoinstall`은 `vm_exec`과 달리 **게스트 내부 명령 실행을 자동화**하는 상위 도구입니다.  
- ISO 기반 자동 설치는 QGA가 없어도 동작하므로, **초기 에이전트 배포 시** 특히 유용합니다.
