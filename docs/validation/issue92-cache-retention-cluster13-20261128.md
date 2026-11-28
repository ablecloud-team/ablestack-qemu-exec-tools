# #92 none 캐시·미검증 대상 보존 검증

검증일: 2026-11-28 KST. 이슈 [#92](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/92),
기존 도구 PR [#88](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/pull/88),
Mold PR [#1989](https://github.com/ablecloud-team/ablestack-cloud/pull/1989)에서 진행했다.
구조화한 증거는 [JSON](issue92-cache-retention-cluster13-20261128.json)에 있다.

## 변경 결과

새 v2k/n2k 작업의 CLI·wizard·manifest·libvirt/Mold 디스크 캐시 기본값은 none이다.
`--target-disk-cache writeback`으로 기존 정책을 명시할 수 있다. ROOT와 DATA가 같은 정책을
사용하며 falloc 기본값은 유지한다. 기존 offering은 수정하지 않는다. 반입을 시작한 작업의
캐시 정책 변경은 차단하고, 캐시 필드가 없는 기존 Mold manifest는 writeback으로 재개한다.

기존 cutover에도 검증 실패 후 VM을 삭제하는 경로는 없었다. 이번 변경은 실패 자원/현재 전원
상태를 유지하면서 manifest에 `RETAINED_UNVERIFIED`, UUID, 실패 단계/이유/종료 코드와 재개
정보를 기록한다. 검증 완료와 구별해 complete/validated=false를 유지한다. n2k define-only와
guest-policy off/BOUND가 complete=true로 기록되던 경우도 보완했다. 성공 재개는 RESOLVED로
전환하되 실패 이력을 보존한다. 보존 처리 자체는 Mold API를 호출하지 않는다.

## 빌드와 배포

RockyLinux-9.7 WSL ext4 작업 트리에서 `make v2k-rpm n2k-rpm`을 성공했다.

| 패키지 | SHA-256 |
|---|---|
| ablestack_v2k-0.10.0-1.el9.el9.x86_64.rpm | d4d7b4bbb493a23a4fb0d8645764fec261b43af0b71410b5852460efcf664aff |
| ablestack_n2k-0.10.0-1.el9.el9.noarch.rpm | 3f2aeed50eb46498e3d89f787c3206989db95053a82d8afb65c714b230a4e8c6 |

RPM에서 새 cache/retention helper와 target_cloud를 추출해 소스와 대조했다. RPM 표준 bash
shebang 정규화 외 본문이 일치했다. 13.1 이관 작업 호스트에는 기존 도구 파일을
`/var/backups/issue92-tools-20261128`에 백업하고 텍스트 런타임만 반영했다. 배포 대상 99개 경로의
SHA-256을 확인했고 최종 갱신은 동일 파일을 건너뛰었다. 관리 서버·agent jar, DB schema,
UI를 교체하거나 서비스를 재시작하지 않았다. Mold의 기존 CacheMode.NONE/API/XML 경로를 사용한다.

## 실제 GFS2 검증

원본 VMware/Nutanix VM에 손대지 않고 1 GiB qcow2/falloc ROOT+DATA로 구성한 독립 fixture를
각 도구의 **실제 production Cloud cutover 함수**에 전달했다. 각 fixture에는 의도적으로
부팅 가능한 OS와 QGA가 없다. 따라서 실제 Mold 조립·기동 이후 guest Verification 시간 초과를
유도하는 실패 시험이며, 이 결과를 OS 부팅 또는 외부 hypervisor 전체 이관 성공으로 해석하지 않는다.

| 도구 | 대상 | VM UUID | 호스트 | 결과 |
|---|---|---|---|---|
| v2k | v2k-i92-cache-none-retained-20261128 / i-2-336-VM | cade01de-aa54-49f2-9996-13a3ecb2f8de | ablecube13-3 | Running, Verification TIMED_OUT, RETAINED_UNVERIFIED |
| n2k | n2k-i92-cache-none-retained-20261128 / i-2-337-VM | 6f02a691-fc34-4a94-a78f-e3c3284c7ab4 | ablecube13-1 | Running, Verification TIMED_OUT, RETAINED_UNVERIFIED |

- 두 VM의 ROOT·DATA 4개 모두 `Ready`, API `cachemode=none`, 실행 XML `cache='none'`이다.
- offering은 각각 `V2K Migration None qcow2 falloc`, `N2K Migration None qcow2 falloc`이다.
- allocation·controller 검증을 통과한 뒤 실제 시작했다. guest 검증 시간 초과로 각 도구는 78을
  반환했고 complete/validated=false였다. 실패를 이유로 VM을 중지하거나 볼륨을 분리/삭제하지 않았다.
- 같은 manifest로 각각 재시도해 다시 78을 반환했다. VM/ROOT/DATA UUID가 모두 같았고 실패 이력은
  각각 2건이다. 중복 자원이 생기지 않았다. Mold에서 두 VM과 각 볼륨을 현재 상태로 보존한다.
- 기존 #91 Windows IDE 성공 작업을 v2k/n2k 각각 재개했다. 기존 VM UUID, source·controller/guest
  plan·storage/cache 의도·offering·반입 request UUID·이미지 경로가 유지됐고, 두 작업은 현재 guest
  VERIFIED와 writeback 볼륨 검증을 통과했다. allocation 관측 receipt는 재조회할 수 있어 전체
  manifest 바이트 일치를 불변 조건으로 사용하지 않았다.

기존 Mold VM 140개의 UUID·이름·상태·호스트 변경은 0건이다. 새 실패 fixture 2대를 포함해
142대이며, 3개 호스트 모두 Up/Enabled, Mold UI HTTP 200을 확인했다.

## 자동 검증

| 검증 | 통과 |
|---|---:|
| 실제 cutover 함수의 allocation/import/start 모의 계약 | 6개 |
| cache 기본값/명시적 override/실제 wizard 메뉴/libvirt XML/명시적 offering 불일치/누락된 volume cache/FAILED·DRIFT·timeout·API 오류 보존/동일 작업 성공 재개/define-only·off | 6개 |
| 이미지·CLI·wizard·설치 레이아웃 | 14개 |
| controller/firmware 및 실제 XML·wizard | 12개 |
| sealed handoff 재개·source/image 재개방 차단 | 5개 |
| Linux·Windows guest 설정 Python 계약 | 40개 |

실패/재개 모의 검증은 VM·ROOT·DATA ID 불변, Running/Stopped 상태 불변, destructive API 호출
부재와 새 import/deploy/start/source-image 조회 부재를 확인했다. 성공 재개는 RESOLVED와 완료
표시, 실패 이력 보존을 확인했다. shellcheck와 `git diff --check`도 통과했다. 원격 CI 상태는
각 PR의 최신 체크를 따른다.

기존 Windows/Ubuntu/Rocky 부팅 및 정적 IP·DATA 복원 실기 결과는 이전 #89/#90/#91 보고서에
해당 정책으로 보존한다. 이번 시험이 그 결과를 none 정책의 OS 부팅 실기로 소급 변경하지 않는다.
