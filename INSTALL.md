# ablestack-qemu-exec-tools 설치 및 배포 가이드

## 1. 준비 사항
- **개발 환경**
  - GitHub 저장소 접근 권한
  - `git` 명령어 사용 가능
- **CI/CD**
  - GitHub Actions 활성화 (`.github/workflows/ci.yml`, `build.yml` 존재)
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

- **VERSION**: 주/부/패치 버전 (`0.3.0`)
- **RELEASE**: 동일 버전 내 빌드 차수 (`1`, `2` …)

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

## 4. GitHub Actions – CI
- **동작 조건**: `push` (main, develop 브랜치), `pull_request`
- **실행 내용**:
  - `make all` 실행 (기본 빌드 검증)
- **목적**: 코드가 깨지지 않았는지 확인

---

## 5. GitHub Actions – Release 빌드
- **동작 조건**: `git tag vX.Y.Z && git push origin vX.Y.Z`
- **실행 내용**:
  - RPM 빌드 (Rocky Linux 9 컨테이너)
  - DEB 빌드 (Ubuntu 최신)
  - MSI 빌드 (Windows + WiX v4)
- **결과물**:
  - GitHub Release에 `.rpm`, `.deb`, `.msi` 자동 업로드
- **릴리즈 노트**:
  - `git log` 기반 자동 생성 (직전 태그 이후 커밋 내역)

---

## 6. 릴리즈 절차
1. **버전 갱신**
   ```bash
   echo "VERSION=0.3.0" > VERSION
   echo "RELEASE=1" >> VERSION
   git add VERSION
   git commit -m "Bump version to 0.3.0-1"
   ```

2. **태그 생성**
   ```bash
   git tag v0.3.0
   git push origin main --tags
   ```

3. **GitHub Actions 실행**
   - Actions 탭에서 워크플로우 확인
   - 빌드 완료 후 Release 페이지 자동 생성

4. **릴리즈 확인**
   - `Release` 페이지에서 `.rpm`, `.deb`, `.msi` 다운로드 가능
   - 릴리즈 노트 = `git log` 자동 생성 내용

---

## 7. 설치 후 확인 (Windows)
MSI 설치 후 PowerShell에서:

```powershell
Get-ItemProperty "HKLM:\SOFTWARE\AbleStack\QemuExecTools" |
  Select-Object Version, Release, GitHash, InstallDir
```

---

## 8. 유지보수 팁
- **새 버전 배포** 시에는 `VERSION` 파일만 수정 → 태그 푸시 → Actions 자동 실행
- **긴급 패치** 시에는 `RELEASE` 값을 증가 (`2`, `3` …)
- **릴리즈 노트 관리**를 더 정교하게 하려면 `CHANGELOG.md`를 추가해도 됨 (현재는 `git log` 기반)

---

# ✅ 요약
- **ci.yml** → 개발 브랜치/PR 빌드 검증  
- **build.yml** → 태그 기반 정식 릴리즈 빌드 & 자동 업로드  
- **사용자는 VERSION 수정 + 태그 푸시만 하면 됨**
