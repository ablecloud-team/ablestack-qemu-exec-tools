# ablestack-qemu-exec-tools 설치 및 배포 가이드

## 1. 준비사항

- **개발 환경**
  - GitHub 저장소 접근 권한
  - `git` 명령어 사용 가능
- **CI/CD**
  - GitHub Actions 설정됨(`.github/workflows/ci.yml`, `build.yml` 존재)
- **필수 파일**
  - `VERSION` (버전 및 릴리즈 번호 정의)
  - `Makefile`
  - `rpm/ablestack-qemu-exec-tools.spec`
  - `deb/control`
  - `windows/msi/build-msi.ps1`, `Product.wxs`

---

## 2. 버전 관리

버전은 `VERSION` 파일에서 관리합니다.

```
VERSION=0.3.0
RELEASE=1
```

- **VERSION**: 메이저/마이너 버전 (`0.3.0`)
- **RELEASE**: 동일 버전 내 빌드 차수 (`1`, `2` 등)

---

## 3. 로컬 빌드 (옵션)

### RPM 빌드 (RHEL 계열)

```bash
make rpm
ls rpmbuild/RPMS/*/*.rpm
```

### DEB 빌드 (Ubuntu 계열)

```bash
make deb
ls build/deb/*.deb
```

### MSI 빌드 (Windows)

```powershell
make windows
Get-ChildItem windows/msi/out/*.msi
```

---

## 4. GitHub Actions 기반 CI

- **?�작 조건**: `push` (main, develop 브랜�?, `pull_request`
- **?�행 ?�용**:
  - `make all` ?�행 (기본 빌드 검�?
- **목적**: 코드가 깨�?지 ?�았?��? ?�인

---

## 5. GitHub Actions ??Release 빌드

- **?�작 조건**: `git tag vX.Y.Z && git push origin vX.Y.Z`
- **?�행 ?�용**:
  - RPM 빌드 (Rocky Linux 9 컨테?�너)
  - DEB 빌드 (Ubuntu 최신)
  - MSI 빌드 (Windows + WiX v4)
- **결과�?*:
  - GitHub Release??`.rpm`, `.deb`, `.msi` ?�동 ?�로??- **릴리�??�트**:
  - `git log` 기반 ?�동 ?�성 (직전 ?�그 ?�후 커밋 ?�역)

---

## 6. 릴리�??�차

1. **버전 갱신**

   ```bash
   echo "VERSION=0.3.0" > VERSION
   echo "RELEASE=1" >> VERSION
   git add VERSION
   git commit -m "Bump version to 0.3.0-1"
   ```

2. **?�그 ?�성**

   ```bash
   git tag v0.3.0
   git push origin main --tags
   ```

3. **GitHub Actions ?�행**
   - Actions ??��???�크?�로???�인
   - 빌드 ?�료 ??Release ?�이지 ?�동 ?�성

4. **릴리�??�인**
   - `Release` ?�이지?�서 `.rpm`, `.deb`, `.msi` ?�운로드 가??   - 릴리�??�트 = `git log` ?�동 ?�성 ?�용

---

## 7. ?�치 ???�인 (Windows)

MSI ?�치 ??PowerShell?�서:

```powershell
Get-ItemProperty "HKLM:\SOFTWARE\AbleStack\QemuExecTools" |
  Select-Object Version, Release, GitHash, InstallDir
```

---

## 8. ?��?보수 ??- **??버전 배포** ?�에??`VERSION` ?�일�??�정 ???�그 ?�시 ??Actions ?�동 ?�행

- **긴급 ?�치** ?�에??`RELEASE` 값을 증�? (`2`, `3` ??
- **릴리�??�트 관�?*�????�교?�게 ?�려�?`CHANGELOG.md`�?추�??�도 ??(?�재??`git log` 기반)

---

# ???�약

- **ci.yml** ??개발 브랜�?PR 빌드 검�?
- **build.yml** ???�그 기반 ?�식 릴리�?빌드 & ?�동 ?�로??
- **?�용?�는 VERSION ?�정 + ?�그 ?�시�??�면 ??*
