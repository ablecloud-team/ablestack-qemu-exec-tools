# Mold 배포까지 preallocation 유지

새 v2k/n2k 파일 대상은 `--target-preallocation off|metadata|falloc|full`을 사용하며 기본값은 `falloc`이다. Wizard에서도 같은 정책을 선택한다. RAW는 metadata를 지원하지 않는다.

Cloud 파일 대상으로 마이그레이션하면 다음 순서로 정책을 보존한다.

1. 소스 스냅샷/전송 전에 Mold와 실제 Agent의 import capability를 조회한다. 계약 버전 1, GFS2, 대상 pool/format/method가 일치해야 진행한다. 오래된 Mold/Agent, 일반 NFS, RBD/block에서는 이 파일 계약을 주장하지 않는다.
2. 정책/형식별 writeback 사용자 정의 디스크 오퍼링을 생성하거나 찾는다. 기존 `thin/sparse/fat` 값으로 정책을 대신하지 않는다. 명시한 오퍼링 ID도 정책·형식·공유/로컬·writeback·활성 상태·태그를 검사한다.
3. 디스크별 UUID를 manifest에 먼저 기록한 다음 `importVolume`에 `allocationpolicy`, `allocationformat`, `allocationcontractversion=1`, `allocationrequestid`, `allocationallowcopy`를 보낸다. 재시도는 같은 UUID를 사용한다.
4. `off/falloc`은 Agent가 실제 파일 형식·크기·할당량을 검사한 뒤 원래 파일을 반입한다. 이 증거는 **반입 시점**의 상태이며 과거 qemu 명령을 추정하지 않는다. `metadata/full`은 운영자가 `--cloud-allocation-copy`로 승인한 경우에만 별도 파일에 preallocation 복사·데이터 비교·원자적 게시를 수행한다. 원본을 변경하지 않으며 추가 공간과 I/O가 필요하다. Wizard는 이 복사 동의를 별도로 받는다. `--yes`는 동의로 간주하지 않는다.
5. VM을 정지 상태로 조립하고 ROOT/DATA 각각의 최종 UUID·pool·path·역할·장치 번호·format·writeback·정책 증거를 `verifyImportedVolumeAllocation`으로 검사한다. 하나라도 맞지 않으면 시작/완료를 막는다. Mold 자체도 첫 시작 전에 모든 해당 볼륨을 다시 검증한다.

예:

```sh
ablestack_n2k wizard --target-provider ablestack-cloud --target-preallocation falloc
ablestack_v2k wizard --target-provider ablestack-cloud --target-preallocation full --cloud-allocation-copy
```

인증/소스/배포 대상의 나머지 필수 값은 기존 Wizard 절차를 따른다. API/SSH 비밀은 manifest나 보고서에 저장하지 않는다.

증거는 `.disks[].transfer.cloud_allocation`, `.runtime.cloud.allocation`, `.runtime.cloud.checkpoint.allocation_verified`에 기록된다. `complete=true`만으로 정책 검증을 대신하지 않는다. 첫 기동 이후 증거는 `historical-first-start` 범위이며 실행 중 이미지에 offline qemu 검사를 하지 않는다. 정책 필드가 없던 기존 manifest는 기존 반입 흐름을 유지하며 새 증거를 소급 생성하지 않는다.

Mold 변경은 별도 upstream Cloud PR이 필요하다. 도구만 업데이트한 환경에서는 capability 검사 단계에서 중단한다. #84의 로컬 이미지 정책과 #87의 최종 배포 계약은 함께 적용해야 한다.
