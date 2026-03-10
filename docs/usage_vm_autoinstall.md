# vm_autoinstall 사용법 (ablestack-qemu-exec-tools)

호스트에서 실행 중인 QEMU/libvirt 기반 가상머신에
**자동으로 ISO를 연결하고, 게스트 OS에 맞게 설치 스크립트를 실행하는 도구**입니다.

vCenter의 게스트 OS에 전송하는 자동 설치 기능처럼, **한 번의 명령으로**
Windows 및 Linux 게스트에 ablestack-qemu-exec-tools를 설치합니다.

---

## 📋 기본 실행 형식

```bash
vm_autoinstall <vm-name> [--force-offline] [--no-reboot]
```

---

## ⚙️ 주요 작동 모드

| 모드 | 조건 | 작동 방식 |
|------|------|-----------|
| **온라인 설치 모드** | 게스트에 `qemu-guest-agent`(QGA)가 실행 중 | VM을 중단하지 않고, 게스트 내부에서 ISO 마운트 후 설치 스크립트(`install-linux.sh` 또는 `install.bat`) 실행 |
| **오프라인 설치 모드** | QGA가 거부되거나 `--force-offline` 지정 | VM 종료 후 스냅샷 찍기 + 주입 + 부팅 시 자동으로 ISO 마운트 후 설치 |
| **Transient VM 지원** | VM이 종료되면 libvirt 목록에서 사라지는 경우 | 종료 직전 XML 및 스냅샷 정보 백업 후 주입 및 `virsh create`로 복기 |
| **Persistent VM** | libvirt에 영구 등록된 VM | 오프라인 주입 후 `virsh start`로 부팅 |

---

## 📋 옵션

| 옵션 | 설명 |
|------|------|
| `--force-offline` | QGA가 작동해도 강제로 오프라인 설치 과정을 수행 |
| `--no-reboot` | 오프라인 모드에서 VM에 주입만 하고 부팅하지 않음 |
| `-h`, `--help` | 사용법 출력 |

---

## 🔄 작동 개요

1. **ISO 연결**
   - `/usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso` 에 VM CD-ROM 디바이스에 연결
   - 기존 ISO가 연결된 경우 자동으로 슬롯 추가 또는 전환 교체 수행
2. **QGA 감지**
   - `virsh qemu-agent-command <vm> '{"execute":"guest-ping"}'` 으로 확인
3. **온라인 설치 (QGA 정상)**
   - 게스트 내부에서 ISO 마운트 후
     - Linux: `/install-linux.sh`
     - Windows: `/install.bat`
   - ?�행 ?�료 ??ISO ?�동 분리
4. **?�프?�인 ?�치 (QGA ?�음)**
   - VM??종료?�고, 게스???��?지???�음 ??��??주입:
     - Linux: `ablestack-install.service` (systemd unit)
     - Windows: `ablestack-runonce.ps1` (RunOnce ?�록)
   - 부????ISO ?�동 마운?????�치 ?�크립트 ?�행
5. **?�기??�?검�?*
   - VM ?�동 기동 (?�는 `--no-reboot`??경우 ?�동 부??
   - ?�치 ?�료 ??ISO ?�동 ?�거 (`detach_iso_safely`)

---

## ?�� ?�제 조건

| ??�� | ?�명 |
|------|------|
| ISO ?�일 | `/usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso` |
| ISO ?�벨 | `"ABLESTACK"` (GitHub Actions?�서 ?�동 지?�됨) |
| ISO 루트 ?�크립트 | Windows ??`install.bat` / Linux ??`install-linux.sh` |
| ?�스???�키지 | `jq`, `virsh`, `libguestfs-tools`, `virt-install`, `virt-xml`(?�택) |

---

## ?�� ?�용 ?�시

### ??기본 ?�용 (QGA 감�? ?�동)
```bash
sudo vm_autoinstall my-vm
```
> QGA가 ?�으�??�라??모드, ?�으�??�프?�인 모드�??�동 ?�환?�니??

### ??QGA가 ?�을 ??강제�??�프?�인 모드�?주입
```bash
sudo vm_autoinstall centos9-vm --force-offline
```

### ???�프?�인 주입�??�고 ?��??��? ?�중??```bash
sudo vm_autoinstall win11-vm --force-offline --no-reboot
```
?�후 ?�동?�로 `virsh start win11-vm`???�행?�면 ?�치가 ?�동 진행?�니??

---

## ?�� 출력 ?�시

```
[INFO] Attaching ISO /usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso
[INFO] QGA 감�??????�라???�치 경로
[OK] Linux 게스???�라???�치 ?�료
[OK] ISO ?�동 분리 ?�료
```

?�는 ?�프?�인 모드??경우:
```
[INFO] ?�프?�인 ?�치 경로 진입
[OK] Linux ?�프?�인 주입 ?�료
[OK] virsh create ?�행 (Transient 부??
```

---

## ?�� ?�동 ?�리 ?�약

1. `libvirt_helpers.sh`??`inject_cdrom_into_xml()`�?ISO ?�전 ?�결  
2. `has_qga()` ??QGA ?�태 ?�단  
3. ?�라??모드: `vm_exec.sh`�??�해 게스???��??�서 ?�치 ?�크립트 ?�행  
4. ?�프?�인 모드:  
   - `offline_inject_linux.sh` / `offline_inject_windows.sh` ?�용  
   - systemd unit ?�는 RunOnce�??�스???��?지??주입  
   - 부????ISO ?�동 마운?????�치 진행  
5. ?�치 ?�료 ??`detach_iso_safely()`�?ISO ?�제

---

## ?�️ 주의?�항

- ?�프?�인 모드?�서??VM??**?�시 중단**?�니??  
- `virt-*` 명령?� 루트 권한???�요?�며, ?��? ?�경?�서??`LIBGUESTFS_BACKEND=direct` ?�정???�요?????�습?�다.  
- ISO ?�일???�거???�상??경우 ?�동 주입???�패?�니??  
- `install.bat` / `install-linux.sh`??ISO 루트??반드??존재?�야 ?�니??

---

## ?�� 관???�일

| ?�일 | ?�명 |
|------|------|
| `bin/vm_autoinstall.sh` | 메인 ?�행 ?�크립트 |
| `lib/libvirt_helpers.sh` | ISO ?�결, QGA 체크, XML 조작 ?�수 |
| `lib/offline_inject_linux.sh` | Linux ?�프?�인 ?�치 주입 로직 |
| `lib/offline_inject_windows.sh` | Windows ?�프?�인 ?�치 주입 로직 |
| `payload/linux/ablestack-install.service` | Linux 부????install-linux.sh ?�행??systemd unit |
| `payload/windows/ablestack-runonce.ps1` | Windows 부????install.bat ?�행??PowerShell |

---

## ?�� 참고

- `vm_autoinstall`?� `vm_exec`�??�리 **게스???��? 명령 ?�행???�동??*?�는 ?�위 ?�구?�니??  
- ISO 기반 ?�동 ?�치??QGA가 ?�어???�작?��?�? **초기 ?�이?�트 배포 ??* ?�히 ?�용?�니??
