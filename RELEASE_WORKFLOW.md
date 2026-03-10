# Release Workflow Guide

이 문서는 ablestack-qemu-exec-tools 프로젝트의 릴리즈 브랜치 전략과 배포 과정을 설명합니다.

---

## 📋 브랜치 전략

- **main**
  - 최종 검증된 코드만 포함
  - GitHub Actions `ci.yml` 실행 결과에 따라 사용
  - 태그(`vX.Y.Z`) 기반으로 공식 릴리즈 생성

- **develop**
  - 새로운 기능 및 버그 수정들을 통합하는 브랜치
  - 모든 기능 브랜치(`feature/*`)들은 PR을 통해 `develop`으로 머지

- **release/* (예: release/0.3.0)**
  - 새로운 릴리즈 준비용 브랜치
  - `VERSION` 파일 설정, 문서 갱신(README, INSTALL.md, RELEASE_WORKFLOW.md 등)
  - 최종 검증 후 `main`으로 병합 및 태그 생성

- **feature/* (예: feature/add-windows-headers)**
  - 개별 기능 개발 브랜치
  - 완료 시 `develop`으로 머지

- **hotfix/* (예: hotfix/fix-msi-path)**
  - 운영 중 긴급 수정 브랜치
  - `main`에서 분기하여 수정 후 `main`과 `develop`으로 모두 병합
  - `VERSION`에 RELEASE 증분 (`0.3.0-2` → `0.3.0-3`)

---

## 🚀 릴리즈 과정

1. **기능 개발**
   - `feature/*` 브랜치에서 개발
   - 완료 시 `develop`으로 머지

2. **릴리즈 준비**
   - `develop`에서 `release/0.3.0` 브랜치 생성
   - `VERSION` 파일 설정 (`VERSION=0.3.0`, `RELEASE=1`)
   - 문서 갱신 (README.md, INSTALL.md, RELEASE_WORKFLOW.md)
   - 테스트 진행

3. **공식 릴리즈**
   - `release/0.3.0` 을 `main` 병합
   - 태그 생성 및 푸시:
     ```bash
     git tag v0.3.0
     git push origin v0.3.0
     ```
   - GitHub Actions `build.yml` 실행으로 `.rpm`, `.deb`, `.msi` 자동 생성 및 Release 업로드
4. **개발 브랜치 갱신**
   - `release/0.3.0` ??`develop`?�도 병합?�여 변경사??반영

---

## ?�� ?�약

- `main`: ?�정/배포?? 
- `develop`: ?�합 개발?? 
- `release/*`: 릴리�?준�?�?검�? 
- `feature/*`: 기능 개발  
- `hotfix/*`: 긴급 ?�치  

릴리즈는 ?�그(`vX.Y.Z`)�?기�??�로 GitHub Actions???�해 ?�동 배포?�니??
