# #1008 코드 수준 설계 — 페일백 사전 점검의 현재 자격 정보 사용

## 원인 확정
Cloud `FtctlDrUnifiedActionAdapter.probeReversePreflight/validateReversePreflight → buildActionCommand(FAILBACK) → buildProfileJson → buildCredentials`는 현재 DR 사이트 자격 정보를 이미 포함한다. 따라서 최초 분석의 “Cloud가 전달하지 않는다”는 추정을 정정한다.

KVM `LibvirtFtctlDrReversePreflightCommandWrapper`는 전달된 profileJson을 소유자 전용 임시 파일로 생성하고 `dr-reverse-preflight --profile-json`에 전달하며 finally에서 삭제한다. qemu `ftctl_dr_kvm_vmware_reverse_preflight`가 이 파일의 credentials를 무시하고 plan의 과거 `/run/.../credentials.json`을 읽는 것이 기능 결함이다.

## 수정
1. qemu `lib/ftctl/dr_kvm_vmware.sh::ftctl_dr_kvm_vmware_reverse_preflight`
   - 입력 JSON에 `credentials` 필드가 있으면 해당 프로필 파일을 이번 lookup의 credential 입력으로 사용한다.
   - 필드가 명시되어 있지만 비었거나 VMware credential이 없으면 과거 runtime credential로 fallback하지 않는다. 폐기된 자격 정보가 되살아나지 않게 한다.
   - `credentials` 필드 자체가 없는 기존 standalone 호출만 기존 runtime 경로를 유지한다.
   - `refresh_target_backings`는 이번 입력의 endpoint/principal/password/govc 설정으로 현재 vCenter disk graph를 조회한다. plan의 credential 파일이나 프로필을 수정하지 않는다.
   - 사전 점검의 임시 map 정리, typed ready/error 응답, source storage/baseline 점검은 유지한다.
2. Cloud `core/.../FtctlDrReversePreflightCommand.profileJson`
   - `@LogLevel(LogLevel.Log4jLevel.Off)`를 추가한다. 이미 전달 중인 자격 정보가 Agent command debug 직렬화에 노출되지 않게 한다.
   - wire serializer는 실제 프로필을 보존하고 logger serializer만 숨기는 회귀 테스트를 추가한다.
3. API/UI/DB 변경 없음. 기존 UI 페일백 버튼은 사전 점검 READY 결과로 활성화된다. 원본 독립 테스트/재해 페일오버에는 원본 접근이나 자격 정보를 다시 요구하지 않는다. VMware 원본/대상 QGA 제외 유지.

## 브랜치 및 기준
양 저장소 `codex/fix-1008-failback-credentials` 생성. #979 Cloud2f79d60836/qemucfad0d4 포함. 최신 upstream Cloud11fc3c536c를 merge bb436f5b73으로 충돌 없이 반영. qemu upstream9d5f543은 이미 포함. #979 브랜치 보존.

## 검증 / 배포
- qemu: runtime credential 없음/오래됨/유효함 + 현재 요청의 유효/폐기/거절 credential 조합, legacy 필드 생략, 원본 runtime 파일 불변, 임시 map 정리 테스트. mock govc는 실제 전달된 환경변수를 검사하며 잘못된 credential을 거절한다.
- Cloud core 변경 Maven 모듈만 WSL ext4에서 빌드. logger에는 비밀이 없고 wire roundtrip에는 동일 프로필이 존재함을 검사. DR/Agent 기존 시험은 필요한 범위로 검증.
- qemu 수정 파일 직접 배포, RPM/전체 빌드 없음. Cloud는 core 명령 클래스만 기존 JAR 엔트리를 보존하며 배포. 사전 백업 및 파일/class 해시 검증.
- 실환경: VMware 원본 독립 테스트 → cleanup → 원본 정지/연결 차단 → 재해 전환 → 연결 복구 → runtime에 원본 자격 정보가 없는 상태에서 UI 페일백 사전 점검 READY → 페일백 성공 → 원본 Running/대상 Stopped/정상 복제 재발행.
- 자격 정보 수동 복구를 하면 자동 체인 PASS로 인정하지 않는다. 비밀 값은 문서/로그/저장소에 기록하지 않는다. 기존 RBD/qcow2 핵심 복제 정상 유지 확인.

## 최종 UI 검증에서 보완한 내부 worker 계약 (2026-09-10)
외부 reverse preflight 요청은 현재 요청의 credentials를 우선하며 빈/무효/target-only 요청으로 runtime 캐시를 되살리지 않는다. 실제 failback worker는 마스킹된 저장 profile을 사용하므로 내부 전용 여섯 번째 인자로 owner-only credentials 파일을 명시한다. 이 인자는 Cloud API/CLI 사용자 옵션으로 노출하지 않는다. 외부 마스킹 요청 거절과 내부 마스킹 profile 실행 성공을 별도로 시험한다. #1011 후속 브랜치에서 이 누락을 함께 보완했다.
