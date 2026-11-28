# 인스턴스/볼륨 가져오기 확대의 qemu tools 계약과 회귀 시험

통합 이슈 [Cloud #2012](https://github.com/ablecloud-team/ablestack-cloud/issues/2012). 기준은 qemu tools `3e2df39` 및 [PR #94](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/pull/94), Cloud [PR #2011](https://github.com/ablecloud-team/ablestack-cloud/pull/2011)이다. 두 PR에서 검증한 RBD 이관은 단독 데이터 볼륨 등록 시험의 기준 환경으로 사용한다.

## 저장소별 경계

| 경로 | Cloud 및 KVM Agent | qemu tools |
| --- | --- | --- |
| 데이터 볼륨 QCOW2·RAW 등록 | 등록 풀에서 파일 검사, 기존 볼륨 API로 같은 풀의 파일을 등록·관리 해제 | 기존 파일형 이관 소비자의 검사 결과와 형식·크기 정합성 검증 |
| 데이터 볼륨 RBD 등록 | 등록된 Ceph 풀의 이미지를 발견·검사하고 현재 RAW 디스크 형식으로 등록 | 목록·등록을 소비하는 V2K·N2K 및 관리 후 KRBD 실행의 호환성 검증 |
| V2K·N2K 이관 | async job, ROOT/DATA 등록과 VM 생성·연결, KRBD 실행 | 절차, 원본 변환과 복사, 게스트 준비, 인계 모드 및 재개 |

현재 `lib/v2k/target_cloud.sh`와 `lib/n2k/target_cloud.sh`가 `listVolumesForImport`로 대상 원본을 확인하고 `importVolume` job을 기다린다. `lib/v2k/guest_configuration_rbd.py`와 V2K·N2K 게스트 준비 코드는 Ceph 이미지 소유권, 검증 및 임시 매핑 수명에 관여한다. 기존 독립 볼륨 등록은 Java KVM Agent를 통해 처리한다. 설정 및 진단 변경은 소비 경로나 기존 Agent에서 확인이 부족한 관측 지점에 한하여 제안한다.

## 인계 계약

- `storageid + path`와 `format`, `storagepooltype`, 바이트 단위를 유지한다. 파일형 QCOW2/RAW와 RBD/RAW를 저장소 유형으로 구분하고 RBD에 파일 기반 preallocation을 적용하지 않는다. RBD가 다른 저장소의 RAW 파일로 표시되지 않도록 목록과 등록 응답을 같이 확인한다.
- 파일 경로는 등록된 풀의 기존 경로를 사용한다. Ceph는 등록된 풀과 해당 image ID, 크기를 대조한다. 이름이 같은 다른 이미지, 다른 pool/namespace, 참조 오류, watcher나 임시 매핑 충돌을 구분한다. 값이 없는 상태를 성공으로 합치지 않는다.
- 기본 볼륨 등록에서 Agent 기존 조회를 재사용한다. 새 관측 유틸리티가 필요한 근거가 확인되면 읽기 전용, 구조화된 결과, 시간 제한, 인증 정보 비노출의 범위로 추가한다. 이 경우 KVM Agent와 패키지 기능 지원 및 구버전 조합을 함께 시험한다.
- 기존 V2K·N2K의 작업 소유권, 변환·게스트 준비·파일/GFS2 경로와 RBD staging·KRBD 해제 계약을 유지한다. 등록이 시작되면 저장된 job/UUID·스토리지 식별자로 이어간다. 중간 실패 시 이전 이미지 덮어쓰기, 관리 이미지의 재복사, 외부가 만든 KRBD 매핑 해제, 타 작업의 임시 데이터 삭제가 발생하지 않아야 한다.
- 파일형·RBD의 정합성은 게스트 데이터 읽기/쓰기까지 확인한다. 32번의 RBD는 Ceph image ID, libvirt XML의 장치와 현재 KRBD 매핑을 대조한다. 재기동 또는 다른 호스트에서 달라질 수 있는 장치 번호는 작업 식별자로 보존하지 않는다.

## 시험 계획

| ID | 준비와 실행 | 통과 기준 |
| --- | --- | --- |
| Q-01 | 소비자 계약 자동시험. 파일형 QCOW2/RAW·RBD/RAW 응답, 기존·추가 필드, 성공·실패 async 응답 | V2K와 N2K 모두 올바른 스토리지 후보와 바이트 크기를 사용하고 job/볼륨 ID가 누락되면 정상 실패 |
| Q-02 | 31번 GFS2와 로컬에 전용 QCOW2·RAW 데이터 이미지. Cloud 등록 후 연결·읽기/쓰기·분리·관리 해제·재등록 | 원본 파일 포맷·가상 크기와 게스트 해시 유지. 해제 후 같은 원본이 조회되고 기존 이미지가 남음 |
| Q-03 | 32번 전용 RBD 이미지. 이름이 같은 다른 이미지 또는 동일 이름으로 교체한 이미지와 정상 이미지, 등록·연결·재기동 | 정상 대상의 image ID·RAW 데이터가 일치. 다른 이미지나 불확실한 접근을 등록/부팅 성공으로 처리하지 않음 |
| Q-04 | 31번 GFS2·32번 RBD에서 V2K·N2K 각각 첫 인계, 2단계 전환과 분리된 ROOT/DATA, Linux/Windows 게스트 | 자격 확인과 기존 등록을 넘겨받고 ROOT/DATA 바인딩·펌웨어·NIC·부팅 및 파일 해시 일치. RBD는 실제 KRBD 증거 포함 |
| Q-05 | 인계 전/후 Agent 응답 지연·실패, 미완료 job, 불일치한 image ID, 제3자의 활성 매핑과 작업 재개 | 응답 상태가 정확하고 API 호출 재실행에 중복 등록/VM 생성이 없음. 기존 원본과 외부 매핑을 보존하고 자기 작업 범위만 정리 |
| Q-06 | 변경 Cloud + 기준 tools, 기준 Cloud + 변경 tools, 두 변경 버전이 배포된 환경 | 호환되는 조합에서 기존 이관이 유지되며, 신규 capability가 있는 경우 미지원 조합에서는 지원 조건을 명확히 보고 |

자동 검증은 기존 `tests/v2k_guest_rbd_test.py`, `tests/mold_preallocation_handoff_test.py`, `tests/v2k_cloud_handoff_resume_test.py`와 V2K/N2K 저장소 경로 스모크를 기준으로 확장한다. 구현에서 공용 DR 경로를 변경하면 해당 공용 동작의 회귀 기준을 적용한다. 실기에서는 최신 배포 패키지 해시·실행 스크립트, Cloud/Agent 버전, API/job UUID, 풀과 이미지 ID 및 게스트 검증 기록을 Cloud #2012에 연결한다. 시험 결과는 대상 환경별로 기록한다.

도구 변경 패키지가 필요한 경우 GitHub Actions에서 빌드한다. 이 문서는 테스트 계획을 정의하며 실제 시험 결과는 이슈에 별도로 남긴다.
