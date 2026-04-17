# ablestack_vm_ftctl ISO Guide

## 목적

이 문서는 OS별 ISO 사용 목적을 정리한다.

## Rocky Linux ISO

대상:

- ABLESTACK Host
- libvirt/QEMU control host

포함 항목:

- base RPM repo
- HANGCTL RPM repo
- FTCTL RPM repo
- V2K RPM repo
- completions
- install-linux.sh
- uninstall-linux.sh

사용:

```bash
mount -o loop ABLESTACK-Tools-rocky-<tag>.iso /mnt
cd /mnt
sudo ./install-linux.sh
```

## Ubuntu ISO

대상:

- Ubuntu guest/admin host

포함 항목:

- deb repos
- completions
- install-linux.sh
- uninstall-linux.sh

## Windows ISO

대상:

- Windows guest

포함 항목:

- MSI
- VirtIO payload
- install.bat
- install.ps1

## Linux uninstall

```bash
cd /mnt
sudo ./uninstall-linux.sh
```

## 참고

- Rocky ISO가 `ftctl` 운영에 가장 중요하다.
- FTCTL add-on 설치는 ABLESTACK Host + Rocky 9 계열 경로를 기준으로 설계되어 있다.
