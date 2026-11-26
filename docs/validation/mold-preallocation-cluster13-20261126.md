# Issue #87: Mold 최종 배포 preallocation 검증 결과

2026-11-26, 운영자가 지정한 13번 GFS2 테스트 클러스터에서 검증했다.

- 도구 PR: https://github.com/ablecloud-team/ablestack-qemu-exec-tools/pull/88
- Cloud PR: https://github.com/ablecloud-team/ablestack-cloud/pull/1989
- 설계: https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/87
- Cloud 코드: `8fe5637b02a` (`ablestack-europa` 기반). 관리 서버와 13-1 Agent의 필요한 클래스만 원본 백업 후 적용했다. 13-2/13-3 Agent 실행 파일은 교체하지 않았다. `WEB-INF`는 보존했다. DB 테이블/컬럼 추가는 없다.

## 실제 검증 범위

소스는 데이터 패턴을 넣은 1 GiB RAW와 BIOS 정지 루프 fixture다. VMware VDDK/Nutanix source reader만 이 fixture로 대체했다. 실제 v2k/n2k 생성·복사 함수, Cloud cutover 함수, Mold 공개 API/DB, KVM Agent, GFS2 파일, VM 조립과 첫 기동을 사용했다. 외부 vCenter/Prism 전체 마이그레이션이나 게스트 OS/QGA 부팅 성공을 의미하지 않는다. UI/API 인증은 메모리에만 유지했으며 비밀 값은 저장하지 않았다.

각 VM은 ROOT 1개 + DATA 1개, 각각 가상 크기 1 GiB다. 두 도구의 7개 형식/정책 조합인 14회 배포와 마지막 실패 처리 보완 후 2회 재확인, 총 16회/32개 볼륨을 검증했다. 모두 첫 기동 전 데이터 비교를 통과하고 `Running`에 도달했다.

| 도구 | 형식 | 정책 | 반입 방식 | ROOT/DATA 최소 관측 할당량(B) | VM 인스턴스 | 기동 호스트 |
| --- | --- | --- | --- | ---: | --- | --- |
| n2k | qcow2 | falloc | adopt | 1076203520 | i-2-278-VM | 13-3 |
| n2k | qcow2 | full | copy | 1076203520 | i-2-287-VM | 13-1 |
| n2k | qcow2 | metadata | copy | 557056 | i-2-286-VM | 13-3 |
| n2k | qcow2 | off | adopt | 536576 | i-2-288-VM | 13-3 |
| n2k | raw | falloc | adopt | 1075871744 | i-2-289-VM | 13-1 |
| n2k | raw | full | copy | 1075871744 | i-2-290-VM | 13-2 |
| n2k | raw | off | adopt | 36864 | i-2-291-VM | 13-1 |
| v2k | qcow2 | falloc | adopt | 1076203520 | i-2-283-VM | 13-2 |
| v2k | qcow2 | full | copy | 1076203520 | i-2-280-VM | 13-2 |
| v2k | qcow2 | metadata | copy | 557056 | i-2-279-VM | 13-3 |
| v2k | qcow2 | off | adopt | 536576 | i-2-282-VM | 13-1 |
| v2k | raw | falloc | adopt | 1075871744 | i-2-281-VM | 13-2 |
| v2k | raw | full | copy | 1075871744 | i-2-284-VM | 13-3 |
| v2k | raw | off | adopt | 36864 | i-2-285-VM | 13-2 |

`off/falloc`은 원래 inode를 유지했다. `falloc/full`은 두 디스크 모두 관측 할당량이 가상 크기 이상이었다. `metadata/full`은 명시적 복사 승인 후 다른 inode에 게시했고 원본 데이터도 보존했다. `off`는 물리 예약을 보장하지 않는다. `metadata/full`의 과거 생성 방법을 추정하거나 기존 파일을 in-place 초기화하지 않았다.

API의 최종 UUID/pool/path/ROOT·DATA 역할/장치 번호/writeback/요청·고정·유효 정책, 기존 `cloud.volumes` 및 `cloud.volume_details`의 저장 값, GFS2 파일 inode/할당량, 실제 배치 호스트의 libvirt XML `type=raw|qcow2`와 `cache=writeback`이 일치했다. 기동 전후 inode도 동일했다. 첫 기동 시점은 `allocation.import.startedat`에 기록됐다.

## 실패·재개 검증

- 정지 상태의 전용 RAW DATA fixture에서 데이터가 모두 0인 256 MiB 구간만 hole punch했다. 가상 크기는 1,073,741,824 B로 유지됐고 데이터 비교도 통과했지만, 물리 할당량은 1,075,871,744 B에서 806,912,000 B로 줄었다.
- `verifyImportedVolumeAllocation`은 `ALLOCATION_EVIDENCE_REQUIRED`로 거부했다. 직접 `startVirtualMachine`도 비동기 작업 실패로 끝났고 VM은 `Stopped`였다. 도구 재개는 새 기동/반입 없이 실패했고 `complete=false`, `allocation_verified=false`를 유지했다.
- 기동 API 실패 및 잘못된 비실행 상태 응답은 완료로 기록하지 않는다. 이전 경고/정의 전용 체크포인트도 요청한 첫 기동이 끝난 것으로 취급하지 않고 같은 UUID로 재개한다.
- 복사 동의가 없는 metadata 요청, 오퍼링과 기대 정책의 불일치를 실제 Mold가 반입 전에 거부했다. 구형 13-2 Agent를 지정한 도구 preflight도 어떤 반입/VM 생성 요청 없이 실패했다.
- 실행 중인 정상 VM에 동일 요청 UUID를 재전송해 같은 볼륨을 재사용했다. 완료된 cutover 재개는 `historical-first-start`로 확인했고 `listVolumesForImport`, 새 반입, 새 기동을 호출하지 않았다. 실행 중 이미지의 offline 검사는 하지 않았다.

## 자동 검증과 CI

- Cloud 관련 41개 Maven 모듈 package, 선택 테스트 145건 통과.
- 도구 이미지/CLI/Wizard 테스트 14건(실제 이미지 복사 조합 21개), 기존 회귀 검사 20건, 최종 Mold 계약 테스트 6건(정상 14개 조합과 거부/기동 실패/실행 중 재개) 통과.
- Shellcheck와 whitespace 검사 통과. Cloud의 새 파일 10개만을 검사한 Apache RAT 결과는 미승인 0건.
- Cloud 연동 전용 CI: https://github.com/ablecloud-team/ablestack-cloud/actions/runs/45777224167 (성공).
- Cloud의 기존 전체 RAT 검사는 기존 파일 미승인 4,074건으로 실패했다. 충돌 라벨 자동화도 다른 PR의 라벨 수정 권한 부족으로 실패했다. 본 PR 자체는 충돌 없이 병합 가능하다. 기존 전체 pre-commit 검사는 별도 진행 상태를 PR에서 확인한다.

## 환경 정리

검증 증거를 먼저 저장한 뒤 이 실행에서 생성한 테스트 VM/볼륨/디스크 오퍼링과 임시 원본 이미지만 정리한다. 기존 VM/저장소/네트워크/오퍼링은 정리 대상에 포함하지 않는다. 관리 서버와 13-1 Agent의 검증용 패치 및 원본 백업은 유지한다. 이 결과는 첫 기동 시점의 계약이며 게스트 쓰기/discard 이후의 지속적인 예약 강제를 주장하지 않는다.
