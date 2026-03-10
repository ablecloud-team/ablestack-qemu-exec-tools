<!-- ablestack-qemu-exec-tools: Copilot 지시서(한국어) -->
# 코드 시나리오에 대한 빠른 이해 (2025년 0월)

이 저장소는 QEMU/libvirt VM 환경에서 qemu-guest-agent를 통해 명령을 실행하는 형편성 유틸리티와 RPM/DEB/MSI 패키징을 제공합니다. AI 코딩 어시스턴트가 즉시 산출물을 만들 수 있도록 프로젝트의 주요 구조와 발견 가능한 핵심 정보를 간결하게 정리합니다.

- 개요
  - 주요 스크립트: `bin/vm_exec.sh`, `bin/agent_policy_fix.sh`, `bin/cloud_init_auto.sh` 및 공통 로직은 `lib/`(특히 `common.sh`, `cloud_init_common.sh`, 서버측 설치)
  - 빌드/패키지: `Makefile`에서 `rpm`, `deb`, `windows` 타깃을 실행합니다. 릴리즈 시 빌드는 GitHub Actions(`.github/workflows/`)에서 자동화됩니다.

- 주요 개발/운영 워크플로우
  - 로컬 설치: `chmod +x install.sh ; sudo ./install.sh` (자세한 사용은 `INSTALL.md`).
  - 패키지 빌드: `make rpm`, `make deb`, `make windows` (Windows는 `powershell` 호출 포함).
  - 구동 실행 예: `vm_exec -l|-w|-d <vm-name> <command> [options]` (`bin/vm_exec.sh`, `docs/usage_vm_exec.md` 참고).

- 코드/작성 규약 (구체적)
  - 모든 스크립트는 POSIX/Bash 스크립트로 작성되어 있습니다. 설치 시 `lib/*`을 `/usr/local/lib/ablestack-qemu-exec-tools`에 복사하고 실행 시 해당 경로에서 `source` 합니다(Makefile 참조).
  - `virsh qemu-agent-command` 호출 결과에 `jq`를 파싱하는 패턴이 많습니다 (`bin/vm_exec.sh`). `jq` 존재를 확인하세요.
  - CSV 출력 규칙에서는 `lib/parse_linux_table.sh`, `lib/parse_windows_table.sh`, `lib/parse_csv.sh` 등이 있으며 출력 파싱이 필요하면 이들 라이브러리를 우선 사용하세요.
  - 지역화: `lib/cloud_init_common.sh`에서 로케일을 감지하여 한국어 메시지를 출력합니다. 사용자 출력 추출 시 `_IS_KO` 플래그를 존중하세요.

- 검증 및 품질
  - 프로젝트의 자동화 수준은 높습니다. 스크립트 문법 검증은 `bash -n <file>` 으로 실행하세요. 특정 에러가 있는 경우 테스트 VM에서 `vm_exec`를 시뮬레이션 실행 권장.
  - 패키지 관련 변경 시 `make deb` / `make rpm` / `make windows`로 빌드 검증하세요.

- 버전/릴리즈 관리
  - 버전 정보는 `VERSION` 파일에서 관리합니다. 버전을 갱신하고 태그(`git tag vX.Y.Z`)를 생성 시 빌드/릴리즈 워크플로우가 자동으로 작동합니다.
  - Windows MSI 빌드는 `windows/msi/` 내 스크립트(`build-msi.ps1`)를 사용합니다.

- 통합 및 주의사항
  - 필수 바이너리(예: `virsh`, `jq`, `dpkg-deb`, `rpmbuild`, `powershell`)는 강하게 존재하니 필요 경로 하드코딩 없이 명령어 이름을 그대로 사용하세요.
  - 개발 중에는 `LIBDIR` 변수를 임시 조정하거나 저장소 루트에서 실행하여 `/usr/local` 설치와 유사한 환경을 만들 수 있습니다.

- 참고 파일 (변경 시 우선 확인)
  - `bin/vm_exec.sh` 주요 명령 작업 설명
  - `lib/common.sh`, `lib/cloud_init_common.sh` 공용 유틸리티 및 cloud-init 관련 로직
  - `docs/usage_vm_exec.md`, `docs/usage_agent_policy_fix.md` 사용법 세부 내용
  - `Makefile`, `rpm/ablestack-qemu-exec-tools.spec`, `deb/control`, `windows/msi/*` 패키지 관련 스크립트/템플릿

추가 한국어 제안이나 로컬 개발 차원(예: Windows에서 MSI 빌드 시 계정 문제 등)에서 느끼는 부분을 알려주세요. 바로 반영하겠습니다.
