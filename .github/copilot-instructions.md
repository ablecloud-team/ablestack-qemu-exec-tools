<!-- ablestack-qemu-exec-tools: Copilot 지침 (한국어) -->
# 코드 어시스턴트를 위한 빠른 안내 (20–50줄)

이 저장소는 QEMU/libvirt VM 내부에서 qemu-guest-agent를 통해 명령을 실행하는 소형 셸 유틸리티들과 RPM/DEB/MSI 패키징을 제공합니다. AI 코딩 에이전트가 즉시 생산적으로 작업할 수 있도록 발견 가능한 핵심 정보를 간결하게 정리했습니다.

- 개요
  - 주요 스크립트: `bin/vm_exec.sh`, `bin/agent_policy_fix.sh`, `bin/cloud_init_auto.sh` — 공통 로직은 `lib/`(특히 `common.sh`, `cloud_init_common.sh`, 파서들)에 위치합니다.
  - 빌드/패키지: `Makefile`에서 `rpm`, `deb`, `windows` 타깃을 실행합니다. 릴리스와 빌드는 GitHub Actions(`.github/workflows/`)로 자동화되어 있습니다.

- 주요 개발/운영 흐름
  - 로컬 설치: `chmod +x install.sh ; sudo ./install.sh` (자세한 내용은 `INSTALL.md`).
  - 패키지 빌드: `make rpm`, `make deb`, `make windows` (Windows는 `powershell` 호출 포함).
  - 도구 실행 예: `vm_exec -l|-w|-d <vm-name> <command> [options]` (`bin/vm_exec.sh`, `docs/usage_vm_exec.md` 참고).

- 코드/런타임 규약 (구체적)
  - 셸 스크립트는 POSIX/Bash 스타일로 작성되어 있습니다. 설치 시 `lib/*`이 `/usr/local/lib/ablestack-qemu-exec-tools`로 복사되고 실행 시 해당 경로에서 `source` 합니다 (Makefile 참조).
  - `virsh qemu-agent-command` 호출 결과를 `jq`로 파싱하는 패턴이 많습니다 (`bin/vm_exec.sh`). `jq` 의존성을 염두에 두세요.
  - 표/CSV 출력 정규화 파서는 `lib/parse_linux_table.sh`, `lib/parse_windows_table.sh`, `lib/parse_csv.sh` 입니다. 출력 파싱이 필요하면 이들 재사용을 우선시하세요.
  - 지역화: `lib/cloud_init_common.sh`는 로케일을 감지해 한국어/영어 메시지를 출력합니다. 사용자 출력 추가 시 `_IS_KO` 플래그를 존중하세요.

- 검증(실무) 팁
  - 저장소에 자동 단위 테스트는 없습니다. 스크립트 문법 검사는 `bash -n <file>` 로 수행하세요. 수정 후에는 가능한 경우 테스트 VM에서 `vm_exec`로 스모크 실행 권장.
  - 패키징 관련 변경은 `make deb` / `make rpm` / `make windows`로 빌드 확인을 수행하세요.

- 버전/릴리스 관련
  - 버전 정보는 `VERSION` 파일에서 읽습니다. 버전을 갱신하고 태그(`git tag vX.Y.Z`)를 푸시하면 빌드/릴리스 워크플로우가 동작합니다.
  - Windows MSI 빌드는 `windows/msi/` 내부 스크립트(`build-msi.ps1`)를 사용합니다.

- 통합 포인트 및 주의사항
  - 외부 바이너리(예: `virsh`, `jq`, `dpkg-deb`, `rpmbuild`, `powershell`)에 강하게 의존합니다. 절대 경로 하드코딩을 피하고 명령어 이름을 그대로 사용하세요.
  - 개발 중에는 `LIBDIR` 변수를 임시로 조정하거나 저장소 루트에서 실행하여 `/usr/local` 설치를 대신할 수 있습니다.

- 참고 파일 (변경 시 우선 확인)
  - `bin/vm_exec.sh` — 핵심 명령 동작과 옵션
  - `lib/common.sh`, `lib/cloud_init_common.sh` — 공용 유틸리티와 cloud-init 관련 로직
  - `docs/usage_vm_exec.md`, `docs/usage_agent_policy_fix.md` — 사용자 예제 및 사용법
  - `Makefile`, `rpm/ablestack-qemu-exec-tools.spec`, `deb/control`, `windows/msi/*` — 패키징 관련 스크립트/템플릿

추가로 한국어 예제나 로컬 개발 절차(예: Windows에서 MSI 빌드 상세 단계 등)를 넣고 싶으면 어느 부분을 확장할지 알려주세요. 제가 바로 반영하겠습니다.
