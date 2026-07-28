# V2K CBT 및 Linux 컷오버 데이터 무결성 강화 설계

## 1. 목적

이 설계는 VMware CBT 기반 증분/최종 동기화에서 전체 디스크 변경 영역이
빠짐없이 수집되었음을 검증하고, 검증되지 않은 결과로 CBT `changeId`가
전진하지 않도록 보장한다.

또한 Linux bootstrap이 파일시스템 mount 오류를 정확히 전달하고, bootstrap
실패 후 선택한 SATA fallback이 manifest와 Cloud 배포 속성에 동일하게
반영되도록 한다.

최우선 원칙은 다음과 같다.

- 전송 성공은 명령 종료 코드가 아니라 전체 소스 구간의 coverage로 판정한다.
- coverage가 불완전하면 대상 디스크를 갱신하거나 `changeId`를 전진하지 않는다.
- 파일시스템 오류를 root 탐색 실패로 바꾸어 보고하지 않는다.
- fallback 선택 이벤트와 실제 대상 VM 컨트롤러 설정은 일치해야 한다.
- sparse/discard 최적화보다 논리 데이터 정확성을 우선한다.

## 2. 장애 배경

3 TiB Rocky Linux 디스크 이관에서 다음 현상이 관찰되었다.

1. base copy는 완료되었다.
2. 첫 번째와 두 번째 incremental sync가 각각 정확히 2,000개 changed extent를
   기록했다.
3. final sync 후 Linux bootstrap이 XFS 파티션을 식별했지만
   `root_partition_not_found`로 종료되었다.
4. SATA로 부팅을 시도해도 XFS가 mount되지 않아 `xfs_repair -L`이 필요했다.
5. SATA fallback 선택 이벤트가 남았지만 Cloud 배포 속성은 SCSI였다.

코드 분석에서 세 가지 독립 결함이 확인되었다.

### 2.1 CBT coverage 누락

`QueryChangedDiskAreas`는 한 호출에서 전체 디스크가 아닌 일부 구간을 반환할 수
있다. 반환 객체의 `startOffset`과 `length`가 그 호출이 설명하는 구간이다.

기존 구현은 항상 `startOffset=0`으로 한 번만 호출하고 `changedArea`만 사용했다.
첫 응답이 전체 디스크보다 짧아도 patch를 성공 처리하고 다음 `changeId`로
전진했다. 이후 동기화는 새 `changeId` 이후 변경만 조회하므로 이전 호출에서
누락된 디스크 후반부 변경은 다시 수집되지 않는다.

### 2.2 bootstrap 반환 코드 손실

bootstrap 명령 캡처 함수의 내부 로컬 변수 이름이 호출자가 전달한 결과 변수
이름과 같았다. Bash의 동적 로컬 스코프에 의해 실제 stderr와 종료 코드가
피호출 함수 내부에서 가려졌고, 호출자는 빈 출력과 `rc=0`을 받았다.

이 때문에 XFS mount가 실패해도 빈 mount 디렉터리에서 배포판 식별 파일을
조회하고 최종적으로 `root_partition_not_found`를 보고할 수 있었다.

### 2.3 SATA fallback manifest 경로 불일치

fallback 선택 코드는 `.bootstrap_fallback`을 기록했지만 Cloud target 코드는
`.runtime.bootstrap_fallback`을 읽었다. 결과적으로 fallback 이벤트는 SATA를
표시하면서 실제 Cloud 배포는 원래 SCSI 컨트롤러를 사용했다.

## 3. CBT 전체 coverage 계약

### 3.1 디스크 용량 결정

CBT helper는 snapshot의 `VirtualDisk`에서 다음 순서로 논리 용량을 구한다.

1. `capacityInBytes`
2. `capacityInKB * 1024`

용량을 확인할 수 없으면 전체 coverage를 증명할 수 없으므로 동기화를
fail-closed로 종료한다.

### 3.2 페이지 반복

초기 `next_offset`은 0이다. 각 호출은 다음과 같이 수행한다.

```text
QueryChangedDiskAreas(
  snapshot=<target snapshot>,
  deviceKey=<disk key>,
  startOffset=next_offset,
  changeId=<previous successful changeId>
)
```

각 응답에 대해 다음 불변식을 검증한다.

- `returned.startOffset == requested startOffset`
- `returned.length > 0`
- `returned.startOffset + returned.length`가 이전 offset보다 커야 한다.
- coverage 끝은 디스크 용량을 초과하지 않아야 한다.
- 모든 changed extent는 현재 응답 coverage 내부에 있어야 한다.
- extent 길이는 0보다 커야 한다.
- 응답에 `changeId`가 포함되는 구현에서는 페이지 간 값이 같아야 한다.

다음 offset은 `returned.startOffset + returned.length`이다. 디스크 용량과 같아질
때까지 반복하며, 중간 gap, 무진행, 범위 초과는 모두 오류다.

### 3.3 helper 출력 계약

CBT helper JSON은 다음 coverage를 포함한다.

```json
{
  "coverage": {
    "mode": "delta",
    "complete": true,
    "start_offset": 0,
    "end_offset": 3298534883328,
    "disk_capacity": 3298534883328,
    "pages": 3
  },
  "areas": []
}
```

`mode=baseline`은 이전 `changeId`가 없어 현재 snapshot을 새 기준점으로
설정하는 경우다. 이때 query page는 없지만 snapshot 디스크 용량을 확인하고
`pages=0`, `complete=true`로 기록한다.

### 3.4 shell 이중 검증

`transfer_patch.sh`는 Python helper가 성공했더라도 다음 조건을 다시 검증한다.

- coverage 객체 존재
- `complete=true`
- `start_offset=0`
- `end_offset=disk_capacity`
- manifest의 `size_bytes`와 `disk_capacity` 일치
- delta는 `pages > 0`, baseline은 `pages == 0`

검증 실패 시:

- `cbt_coverage_incomplete` 이벤트 기록
- patch 실행 금지
- `changeId` 전진 금지
- 종료 코드 44 반환

helper 자체가 실패하면 `cbt_query_failed` 이벤트에 종료 코드와 축약된 오류를
기록한다.

## 4. changeId 커밋 모델

`changeId`는 다음 조건을 모두 충족한 뒤에만 전진한다.

1. CBT 전체 coverage 검증 성공
2. 모든 changed extent 읽기 성공
3. 대상 쓰기 또는 zero/discard 성공
4. 대상 `fsync`/flush 완료

manifest 갱신은 한 번의 임시 파일 + rename으로 다음 값을 함께 기록한다.

- `cbt.base_change_id`
- `cbt.last_change_id`
- `cbt.last_coverage`

예:

```json
{
  "cbt": {
    "base_change_id": "...",
    "last_change_id": "...",
    "last_coverage": {
      "phase": "final",
      "mode": "delta",
      "complete": true,
      "start_offset": 0,
      "end_offset": 3298534883328,
      "disk_capacity": 3298534883328,
      "pages": 3,
      "areas": 3175,
      "bytes": 7516192768,
      "start_change_id": "...",
      "new_change_id": "...",
      "ts": "..."
    }
  }
}
```

프로세스가 coverage 검증 또는 patch 도중 종료되면 이전 `last_change_id`가
유지되므로 다음 재시도에서 같은 변경 구간을 다시 조회할 수 있다.

## 5. Linux bootstrap 오류 보존

명령 캡처 함수의 내부 변수는 호출자 결과 변수와 겹치지 않는 고유 이름을
사용한다.

계약:

- stdout/stderr를 단일 행으로 축약해 호출자와 이벤트에 동일하게 전달
- 실제 종료 코드를 호출자 결과 변수와 이벤트 `detail.rc`에 동일하게 전달
- mount 실패 시 `mount_try_partition_failed`가 실제 오류 코드와 메시지를 보유
- 실패한 mount 디렉터리에서 배포판 identity probe를 실행하지 않음

따라서 XFS 로그 또는 메타데이터 오류는 root 미발견으로 변환되지 않고 실제
mount 오류로 진단할 수 있다.

## 6. SATA fallback 일관성

fallback 상태의 canonical manifest 경로는 다음 하나로 고정한다.

```text
.runtime.bootstrap_fallback
```

Cloud와 libvirt target 모두 이 경로만 읽는다.

Cloud cutover 전 생성되는 deploy property는 fallback이 SATA일 때 다음을
포함해야 한다.

```json
{
  "details[0].rootDiskController": "sata"
}
```

단, SATA fallback은 initramfs의 virtio 드라이버 부재를 우회하는 기능이다.
이미 손상되거나 불완전한 파일시스템을 복구하는 기능으로 취급하지 않는다.

## 7. RBD sparse/discard와의 관계

RBD sparse patch는 전체 CBT coverage가 검증된 changed extent에만 적용한다.

- all-zero chunk이면 discard를 시도한다.
- discard 실패 시 동일 zero 데이터를 일반 write한다.
- non-zero chunk는 항상 일반 write한다.
- sparse 최적화가 coverage 누락을 보완하거나 숨기면 안 된다.
- coverage 실패 시 sparse/non-sparse와 관계없이 patch 자체를 시작하지 않는다.

운영 진단을 위해 `changed_areas_fetched`, `no_changes`, `disk_done` 이벤트에
coverage 객체를 포함한다.

## 8. 수동 종료 정책

`--shutdown manual`은 운영자가 source VM을 종료했다는 전제다. 데이터 무결성을
강화하려면 final snapshot 생성 전에 `runtime.powerState=poweredOff`를 확인하고
아니면 중단하는 후속 개선이 필요하다.

이번 변경은 확인된 CBT 및 bootstrap 결함 수정에 집중하며 CLI의 manual 정책은
변경하지 않는다.

## 9. 검증 설계

### 9.1 CBT smoke

가짜 pyVmomi VM을 사용해 다음을 검증한다.

- 3페이지 응답을 0부터 디스크 끝까지 연속 호출
- 모든 페이지 extent 병합
- coverage page 수와 끝 offset 기록
- length 0 응답 fail-closed
- 요청 offset과 다른 응답 fail-closed
- 디스크 범위를 벗어난 extent fail-closed

### 9.2 cutover integrity smoke

- 실패 명령의 stderr와 종료 코드가 capture wrapper를 통과해 보존되는지 확인
- 존재하지 않는 장치 mount가 성공으로 오인되지 않는지 확인
- SATA fallback이 `.runtime.bootstrap_fallback`에 기록되는지 확인
- Cloud deploy property가 실제로 SATA를 선택하는지 확인
- 불완전 coverage가 shell validator에서 거부되는지 확인
- changeId와 coverage가 한 manifest 갱신으로 기록되는지 확인

### 9.3 정적 및 패키지 검증

- 수정 shell 파일 `bash -n`
- 수정 Python 파일 `py_compile`
- 신규 및 기존 관련 smoke test
- `make v2k-rpm`
- 생성 RPM에 수정된 v2k 라이브러리, 문서, completion 포함 여부 확인

## 10. 운영 전환 기준

다음 조건을 모두 만족해야 수정 버전을 실환경 이관에 사용할 수 있다.

- 단위 smoke와 기존 v2k smoke 통과
- RPM 로컬 빌드 통과
- 대용량 테스트 디스크에서 CBT page 수가 2 이상인 사례 검증
- 모든 증분/final 이벤트의 coverage가 `complete=true`
- 이관 후 읽기 전용 파일시스템 검사 및 애플리케이션 데이터 검증 통과

기존 불완전 이관 디스크를 `xfs_repair -L`로 복구한 결과는 새 구현의 검증
대상으로 재사용하지 않는다. 새 workdir과 새 대상 이미지로 재이관한다.
