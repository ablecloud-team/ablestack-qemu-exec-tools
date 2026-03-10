# Changelog

이 문서는 ablestack-qemu-exec-tools 프로젝트의 모든 변경 이력을 기록합니다.
형식은 [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)를 참고하며
버전 기기는 [Semantic Versioning](https://semver.org/)을 따릅니다.

---

## [Unreleased]
### Added
- 새로운 기능 추가 예정 목록

### Changed
- 변경 예정 사항

### Fixed
- 수정 예정 버그 목록

---

## [0.3.0] - 2025-09-25
### Added
- Windows MSI 빌드 스크립트(`build-msi.ps1`) 버전/릴리즈 깃해시 반영
- Product.wxs에 설치 버전/릴리즈 깃해시를 MSI 생성 시 메트리에 기록하는 기능 추가
- GitHub Actions `build.yml` 에 릴리즈 자동화(RPM/DEB/MSI 빌드 및 Release 업로드)

### Changed
- Makefile: `VERSION` 파일 참조 방식으로 변경
- RPM spec/DEB control: 자동으로 버전/릴리즈 반영하도록 수정

### Fixed
- Windows 빌드 시 WiX 장치 처리 수정
- DEB 패키지 control 파일 버전 하드코딩 문제 수정

---

## [0.2.0] - 2025-09-15
### Added
- Linux용 vm_exec.sh, agent_policy_fix.sh 스크립트 작성
- DEB/RPM 패키지 초기 지원
- GitHub Actions ci.yml 추가

---

## [0.1.0] - 2025-08-30
### Added
- 프로젝트 초기 생성
- 기본 VM 게스트 명령 실행 기능 (Linux/Windows)
