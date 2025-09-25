# Release Workflow Guide

이 문서는 ablestack-qemu-exec-tools 프로젝트의 릴리즈 브랜치 전략과 배포 절차를 설명합니다.

---

## 📌 브랜치 전략

- **main**
  - 항상 안정화된 코드만 포함
  - GitHub Actions `ci.yml` 실행 대상으로 사용
  - 태그(`vX.Y.Z`) 기준으로 정식 릴리즈 생성

- **develop**
  - 새로운 기능 및 버그 수정이 통합되는 브랜치
  - 모든 기능 브랜치(`feature/*`)는 PR을 통해 `develop`으로 머지

- **release/* (예: release/0.3.0)**
  - 새로운 릴리즈 준비용 브랜치
  - `VERSION` 파일 수정, 문서 갱신(README, INSTALL.md, RELEASE_WORKFLOW.md 등)
  - 최종 검증 후 `main`으로 병합 → 태그 생성

- **feature/* (예: feature/add-windows-headers)**
  - 단위 기능 개발 브랜치
  - 완료 시 `develop`에 머지

- **hotfix/* (예: hotfix/fix-msi-path)**
  - 운영 중 긴급 패치 브랜치
  - `main`에서 분기 → 수정 후 `main`과 `develop`에 모두 병합
  - `VERSION`의 RELEASE 값 증가 (`0.3.0-2` → `0.3.0-3`)

---

## 📌 릴리즈 절차

1. **기능 개발**
   - `feature/*` 브랜치에서 개발
   - 완료 후 `develop`에 머지

2. **릴리즈 준비**
   - `develop`에서 `release/0.3.0` 브랜치 생성
   - `VERSION` 파일 수정 (`VERSION=0.3.0`, `RELEASE=1`)
   - 문서 갱신 (README.md, INSTALL.md, RELEASE_WORKFLOW.md)
   - 테스트 진행

3. **정식 릴리즈**
   - `release/0.3.0` → `main` 병합
   - 태그 생성 및 푸시:
     ```bash
     git tag v0.3.0
     git push origin v0.3.0
     ```
   - GitHub Actions `build.yml` 실행 → `.rpm`, `.deb`, `.msi` 자동 생성 및 Release 업로드

4. **개발 브랜치 갱신**
   - `release/0.3.0` → `develop`에도 병합하여 변경사항 반영

---

## 📌 요약

- `main`: 안정/배포용  
- `develop`: 통합 개발용  
- `release/*`: 릴리즈 준비 및 검증  
- `feature/*`: 기능 개발  
- `hotfix/*`: 긴급 패치  

릴리즈는 태그(`vX.Y.Z`)를 기준으로 GitHub Actions에 의해 자동 배포됩니다.
