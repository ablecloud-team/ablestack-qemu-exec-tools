# v2k/n2k 디스크 캐시와 미검증 대상 보존

이슈: [#92](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/92)

새 작업은 CLI와 wizard, libvirt와 Mold 모두 `--target-disk-cache none`이 기본값이다.
호스트 페이지 캐시를 사용하는 기존 동작이 필요하면 `--target-disk-cache writeback`을 명시한다.
`--target-preallocation`의 기본값 `falloc`은 그대로이며 캐시 옵션과 독립적이다.

```bash
ablestack_v2k wizard --target-disk-cache none
ablestack_n2k wizard --target-disk-cache writeback
```

위 예에는 원본·대상·인증 등 환경별 필수 인수를 추가한다. 대화형 wizard에는 캐시 선택 메뉴가 있고,
`--yes`와 `--print-command`도 정책을 명시해 실제 run으로 전달한다. 미리보기는 자원을 생성하지 않는다.
새 manifest는 `target.storage.cache_mode`에 정책을 기록한다.

Mold는 ROOT와 DATA 모두 같은 캐시 정책으로 생성한다. 별도 `V2K Migration None` 또는
`N2K Migration None` offering을 사용하며 로컬 저장소에는 `Local`, 명시적 allocation 계약에는
형식과 정책 이름이 붙는다. 기존 Writeback offering을 수정하지 않는다. 사용자가 offering ID를
지정해도 요청한 캐시·저장소·allocation 계약을 검증한다. 최종 `listVolumes`의 각 볼륨 ID,
VM ID, device ID, Ready 상태 및 cachemode가 일치해야 한다. 누락된 cachemode를 none으로 추정하지 않는다.

기존 Mold manifest에 캐시 필드가 없으면 기존 writeback 정책으로 해석한다. 기존 libvirt 작업은
none을 유지한다. Mold 반입이 시작된 뒤에는 다른 캐시 정책으로 바꿀 수 없다
(`TARGET_CACHE_POLICY_FROZEN`, 종료 코드 44). 기존 VM의 설정을 소급 변경하지 않는다.

## Verification이 끝나지 않은 경우

기존 Cloud cutover도 실패 후 VM/볼륨을 자동 삭제하지 않았다. 이번 변경은 이 경로에 명시적인
보존 기록과 재개 정보를 추가하고, n2k의 define-only/BOUND 완료 판정을 v2k와 일치시킨다.

| 결과 | Mold 자원 | 도구 결과 |
|---|---|---|
| 검증 완료 | 현재 상태 유지 | complete/validated=true, 이전 보존 기록은 RESOLVED |
| FAILED·DRIFT·시간 초과·API 오류·기타 cutover 실패 | 알려진 VM/ROOT/DATA 및 현재 전원 상태 보존 | 실패 종료 코드를 유지, RETAINED_UNVERIFIED |
| apply/define-only, guest-config-policy off 등 검증 생략 | 생성된 자원과 현재 상태 보존 | 명시적으로 요청한 작업은 종료 코드 0, complete/validated=false |

보존은 항상 적용되므로 별도 keep-on-failure 옵션이 필요하지 않다. 검증 실패를 이유로 stop,
destroy, expunge, detach, delete를 호출하지 않는다. 기동 전 allocation/controller 검증이 막힌
대상은 정지 상태로 남으며, 보존 처리가 그 안전장치를 우회해 VM을 시작하지 않는다.

`runtime.cloud.retention`에는 `status`, `exit_code`, 원래 `phase`, `reason`, VM/ROOT/DATA UUID,
진행 중 job ID, manifest 위치 및 재개 안내를 기록한다. 실패 이력은 성공 후에도 보존한다.
`runtime.cloud.checkpoint.complete=false`, `runtime.cloud.validated=false`,
`inspection_required=true`로 완료와 구별한다. 시간 초과는 로컬 guest 상태를 TIMED_OUT으로
기록한다. 이 기록은 도구 manifest의 상태이며 Mold VM의 Running/Stopped 상태를 대체하지 않는다.

Mold에서 남은 대상을 확인하거나 보완한 뒤 **같은 workdir/manifest와 원래 정책**으로 cutover 또는
run을 재개한다. 새 init으로 작업을 바꾸지 않는다. VM·볼륨 ID와 반입 request UUID를 재사용하며,
handoff 뒤에는 원본 재복사·managed 이미지 재개방·게스트 helper 교체를 수행하지 않는다.
정상 검증 후 이전 보존 기록은 RESOLVED가 된다. 기존 게스트 인증·네트워크·디스크 검증을 생략해
성공으로 바꾸는 옵션은 추가하지 않는다.

검증 근거: [13번 클러스터 검증 보고서](validation/issue92-cache-retention-cluster13-20261128.md).
