# ablestack_n2k 설계 문서

## 목적

`ablestack_n2k`는 Nutanix AHV 환경의 가상머신을 ABLESTACK(KVM/libvirt) 환경으로 이전하기 위한 별도 마이그레이션 도구이다.

기존 `ablestack_v2k`와 병합하지 않는다. `ablestack_v2k`는 VMware 전용 도구로 유지하고, `ablestack_n2k`는 Nutanix 전용 도구로 독립 구현한다. 다만 명령 체계, manifest 기반 상태 관리, 단계별 실행 모델, target storage 처리 방식은 `ablestack_v2k`의 경험을 참고한다.

## 개발 원칙

이 브랜치에서 `ablestack_n2k` 개발 시 다음 규칙을 반드시 따른다.

- Markdown 문서는 한글로 작성하고 관리한다.
- Markdown 문서 작성 후 한글 깨짐 여부를 확인한다.
- 모든 리눅스 실행 코드는 LF 줄바꿈으로 관리한다.
- 소스코드는 영어를 원칙으로 한다.
- 소스코드의 사용자 출력 메시지, 로그 메시지, 에러 메시지, 주석은 모두 영어로 작성한다.
- 소스코드에는 한글 메시지와 한글 주석을 넣지 않는다.
- 빌드는 GitHub Actions를 이용한다.
- 로컬 빌드는 수행하지 않는다.
- 로컬에서는 문법 점검, 정적 검토, 파일 내용 확인 수준만 수행한다.
- 바이너리 파일은 명시 요청 없이는 수정하지 않는다.

## 설계 방향

`ablestack_n2k`는 Nutanix 환경을 떠나는 사용자를 대상으로 한다. 따라서 최신 Nutanix API 사용을 전제로만 설계하면 안 된다. 최신 Prism Central 또는 AOS로 업그레이드할 수 없는 고객도 마이그레이션 경로를 가져야 한다.

이에 따라 기능을 단일 경로가 아니라 여러 지원 모드로 나눈다.

| 모드 | 목적 | 다운타임 | 지원 수준 |
| --- | --- | --- | --- |
| `v4-incremental` | v4 Data Protection API 기반 증분 마이그레이션 | 낮음 | 정식 권장 |
| `legacy-cbt` | 구버전 API의 changed-region 기능 탐지 및 사용 | 낮음 또는 중간 | 실험적 |
| `cold-export` | 전체 디스크 복제 기반 마이그레이션 | 높음 | 정식 fallback |
| `manual-disk` | 사용자가 제공한 디스크 이미지를 KVM VM으로 구성 | 사용자 의존 | 정식 rescue |

기본 실행 모드인 `auto`는 `preflight` 결과를 바탕으로 가능한 최선의 모드를 선택한다. 단, 실험적 모드인 `legacy-cbt`는 명시 옵션 없이는 자동 선택하지 않는다.

## Nutanix API 전략

### v4 우선 전략

Nutanix v4 API는 Prism Central 중심의 최신 API이며, VM 관리와 Data Protection 기능이 namespace 단위로 제공된다. `v4-incremental` 모드에서는 다음 기능을 사용한다.

- VM 인벤토리 조회
- VM Recovery Point 생성 또는 조회
- Disk Recovery Point 식별
- Recovery Point 간 changed regions 계산
- Prism Element redirect/JWT 기반 changed regions 조회

`v4-incremental`은 `ablestack_v2k`의 base/incr/final 흐름에 가장 가깝다.

### legacy API 고려

Nutanix를 떠나려는 사용자는 Prism Central 또는 AOS를 업그레이드하지 못할 수 있다. 이 경우 v4 API를 요구하면 마이그레이션 도구의 실효성이 떨어진다.

따라서 `ablestack_n2k`는 legacy API를 완전히 배제하지 않는다. 다만 legacy API는 deprecated 예정이며 기능 표면이 v4와 다르고 환경 의존성이 높으므로, 다음 원칙을 적용한다.

- legacy API는 정식 기본 경로가 아니라 fallback 또는 experimental 경로로 취급한다.
- `preflight`에서 legacy changed-region API 또는 동등 기능의 접근 가능성을 탐지한다.
- 기능이 확인되지 않으면 `cold-export`로 안내한다.
- legacy API 사용은 manifest와 events log에 명확히 기록한다.
- `legacy-cbt`는 `--allow-experimental` 또는 동등한 명시 옵션이 있을 때만 실행한다.

### cold fallback

구버전 환경에서 changed-region 기능을 안정적으로 사용할 수 없더라도 마이그레이션은 가능해야 한다. 이 경우 전체 디스크를 복제하는 `cold-export` 모드를 제공한다.

`cold-export`는 VM을 종료하거나 일관성 있는 snapshot/export 지점을 확보한 뒤 전체 디스크를 target storage로 복제한다. 다운타임은 길지만, API 버전 요구사항이 낮고 탈출 경로로서 가치가 높다.

## 명령 체계

명령 체계는 `ablestack_v2k`와 유사하게 유지한다.

```bash
ablestack_n2k [global options] <command> [command options]
```

### 전역 옵션

| 옵션 | 설명 |
| --- | --- |
| `--workdir <path>` | 작업 디렉터리 지정 |
| `--run-id <id>` | 실행 ID 지정 |
| `--manifest <path>` | manifest 경로 지정 |
| `--log <path>` | events log 경로 지정 |
| `--json` | JSON 출력 |
| `--dry-run` | 변경 작업 없이 계획 검토 |
| `--resume` | 기존 manifest 기반 재개 |
| `--force` | 위험 작업 허용 |

### 명령

| 명령 | 설명 |
| --- | --- |
| `preflight` | Nutanix API, 권한, 버전, target host 조건 점검 |
| `plan` | VM별 가능한 마이그레이션 모드와 위험 요소 산출 |
| `run` / `auto` | 전체 마이그레이션 파이프라인 실행 |
| `init` | workdir 및 manifest 생성 |
| `snapshot` | Nutanix snapshot 또는 recovery point 생성 |
| `sync` | base/incr/final 데이터 동기화 |
| `verify` | 대상 디스크와 manifest 상태 검증 |
| `cutover` | final sync, libvirt define/start 수행 |
| `cleanup` | 임시 리소스 정리 |
| `status` | manifest와 events log 기반 상태 출력 |

### 실행 예

```bash
ablestack_n2k preflight \
  --pc pc.example.local \
  --username admin
```

```bash
ablestack_n2k plan \
  --vm app-01 \
  --pc pc.example.local \
  --cred-file ./nutanix.env
```

```bash
ablestack_n2k run \
  --vm app-01 \
  --pc pc.example.local \
  --cred-file ./nutanix.env \
  --mode auto \
  --dst /var/lib/libvirt/images/app-01 \
  --target-format qcow2 \
  --target-storage file
```

```bash
ablestack_n2k run \
  --vm app-01 \
  --pc pc.example.local \
  --cred-file ./nutanix.env \
  --mode cold-export
```

```bash
ablestack_n2k run \
  --vm app-01 \
  --pc pc.example.local \
  --cred-file ./nutanix.env \
  --mode legacy-cbt \
  --allow-experimental
```

## 디렉터리 구조

초기 구현은 `v2k`와 병합하지 않고 독립 디렉터리에 배치한다.

```text
bin/ablestack_n2k.sh
lib/n2k/engine.sh
lib/n2k/orchestrator.sh
lib/n2k/manifest.sh
lib/n2k/nutanix_api.sh
lib/n2k/transfer_base.sh
lib/n2k/transfer_patch.sh
lib/n2k/verify.sh
lib/n2k/logging.sh
docs/n2k/
examples/n2k/
tests/n2k/
```

단, 다음 공통 기능은 중복 구현을 피하기 위해 추후 `lib/common/` 계층으로 분리할 수 있다.

- libvirt XML 생성
- target device 준비
- NBD 유틸리티
- patch apply 로직
- events log writer
- Linux bootstrap
- Windows WinPE bootstrap

초기 단계에서는 공통화보다 `n2k` 기능 검증을 우선한다.

## manifest 설계

manifest는 실행 상태의 단일 기준이다. `v2k` manifest와 비슷한 구조를 유지하되 Nutanix 전용 필드를 둔다.

```json
{
  "schema": "ablestack-n2k/manifest-v1",
  "run": {
    "run_id": "20260428-120000",
    "created_at": "2026-04-28T12:00:00+09:00",
    "workdir": "/var/lib/ablestack-n2k/app-01/20260428-120000"
  },
  "source": {
    "type": "nutanix",
    "mode": "v4-incremental",
    "pc": "pc.example.local",
    "cluster": {},
    "api": {
      "family": "v4",
      "namespaces": {
        "vmm": "available",
        "dataprotection": "available"
      }
    },
    "vm": {}
  },
  "target": {
    "type": "kvm",
    "format": "qcow2",
    "dst_root": "/var/lib/libvirt/images/app-01",
    "storage": {
      "type": "file",
      "map": {}
    },
    "libvirt": {
      "name": "app-01"
    }
  },
  "disks": [],
  "phases": {},
  "runtime": {}
}
```

### source 주요 필드

| 필드 | 설명 |
| --- | --- |
| `source.mode` | `v4-incremental`, `legacy-cbt`, `cold-export`, `manual-disk` |
| `source.pc` | Prism Central 주소 |
| `source.pe` | Prism Element 주소 또는 cluster endpoint |
| `source.api.family` | 사용 API 계열 |
| `source.api.namespaces` | namespace별 사용 가능 여부 |
| `source.vm` | VM 이름, UUID, CPU, memory, firmware, NIC, guest OS 정보 |

### disk 주요 필드

| 필드 | 설명 |
| --- | --- |
| `disk_id` | n2k 내부 디스크 식별자 |
| `nutanix.ext_id` | Nutanix disk external identifier |
| `nutanix.vdisk_uuid` | legacy 또는 PE 경로에서 사용하는 vDisk UUID |
| `size_bytes` | 디스크 크기 |
| `controller` | bus, adapter, unit 정보 |
| `recovery_points` | base/incr/final recovery point 참조 |
| `transfer.target_path` | 대상 파일, 블록 디바이스, 또는 RBD URI |
| `metrics` | 복제 바이트, changed region 수, 소요 시간 |

## preflight 설계

`preflight`는 실행 가능성을 판단하고 사용자에게 업그레이드 없이 가능한 경로를 제시한다.

점검 항목은 다음과 같다.

- Prism Central 접속 가능 여부
- Prism Element 접속 가능 여부
- 인증 방식과 권한
- Prism Central 버전
- AOS 버전
- AHV 버전
- v4 `vmm` namespace 사용 가능 여부
- v4 `dataprotection` namespace 사용 가능 여부
- VM 조회 가능 여부
- Recovery Point 생성 가능 여부
- changed regions API 사용 가능 여부
- legacy changed-region 기능 탐지 결과
- cold export에 필요한 접근 경로
- target host의 `qemu-img`, `qemu-nbd`, `virsh`, `jq` 등 필수 명령
- target storage 타입별 쓰기 가능 여부

출력 예시는 다음과 같다.

```text
Detected Prism Central: pc.2022.x
Detected AOS: 6.x
v4 dataprotection changed-regions: unavailable
legacy changed-regions: not verified
cold export: available
recommended mode: cold-export
minimal downtime: unavailable
```

```text
Detected Prism Central: pc.7.3
Detected AOS: 7.3
v4 vmm: available
v4 dataprotection: available
recommended mode: v4-incremental
minimal downtime: available
```

## 데이터 전송 설계

### base sync

`base sync`는 source disk의 전체 내용을 target disk로 복제한다.

`v4-incremental`에서는 base recovery point 기준 디스크 데이터를 읽는다. `cold-export`에서는 shutdown 또는 snapshot 지점의 전체 디스크를 읽는다.

target storage는 다음을 지원한다.

- file + qcow2
- file + raw
- block
- rbd

### incremental sync

`incremental sync`는 이전 recovery point와 현재 recovery point 사이의 changed regions를 가져와 target disk에 patch한다.

기본 흐름은 다음과 같다.

1. 새 recovery point 생성
2. 이전 recovery point와 새 recovery point 사이의 changed regions 조회
3. changed regions를 offset/length 목록으로 정규화
4. source disk reader에서 해당 영역을 읽음
5. target disk에 patch 적용
6. 성공 시 manifest의 기준 recovery point 갱신

### final sync

`final sync`는 cutover 중 source VM을 정지한 뒤 마지막 recovery point를 만들고 changed regions를 반영한다.

이 단계가 성공해야 libvirt VM define/start를 진행한다.

## 디스크 데이터 읽기 전략

`ablestack_n2k`의 가장 중요한 기술 과제는 Recovery Point 또는 snapshot 기준의 디스크 데이터를 안정적으로 읽는 것이다.

후보 경로는 다음과 같다.

| 경로 | 설명 | 상태 |
| --- | --- | --- |
| v4 recovery point data access | 공식 API 또는 SDK로 recovery point disk를 읽는 방식 | 우선 조사 |
| PE/CVM export path | storage container 또는 vDisk export 경로를 이용 | 환경 의존 |
| temporary clone VM/disk | recovery point에서 임시 clone을 만들고 해당 disk를 읽음 | 안전성 검토 필요 |
| full image export | 전체 이미지를 export한 뒤 변환 | cold fallback |
| manual disk input | 사용자가 제공한 qcow2/raw/vDisk를 입력으로 사용 | rescue |

PoC의 1차 목표는 `base sync` 가능한 안정적 disk read path를 확보하는 것이다. changed regions API보다 disk data read path가 더 큰 리스크이다.

## cutover 설계

`cutover`는 다음 순서로 진행한다.

1. source VM shutdown 또는 poweroff
2. final recovery point 또는 final snapshot 생성
3. final changed regions 조회
4. final sync 수행
5. Linux guest bootstrap 필요 여부 판단
6. Windows guest WinPE bootstrap 필요 여부 판단
7. libvirt XML 생성
8. VM define
9. 필요 시 VM start
10. manifest phase 갱신

guest OS 처리 정책은 `v2k`의 경험을 참고한다.

- Linux는 virtio/initramfs 준비 상태를 확인한다.
- Windows는 virtio driver 주입 또는 WinPE bootstrap 경로를 제공한다.
- Secure Boot, TPM, UEFI 정보는 source inventory에서 가능한 범위 내에서 보존한다.

## cleanup 설계

cleanup은 안전을 우선한다.

- 기본적으로 source VM의 원본 데이터는 삭제하지 않는다.
- recovery point 삭제는 명시 옵션 또는 정책에 따라 수행한다.
- experimental legacy path에서 생성한 임시 리소스는 manifest에 기록된 것만 정리한다.
- 실패 시 사용자가 수동 정리할 수 있도록 리소스 목록을 출력한다.

## 로그와 상태 관리

모든 주요 단계는 events log에 기록한다.

로그 메시지는 소스코드 규칙에 따라 영어로 작성한다.

기록 항목은 다음을 포함한다.

- phase start/done/fail
- API endpoint family
- selected migration mode
- source VM identity
- disk identity
- recovery point identity
- changed region count
- transferred bytes
- target path
- cleanup actions
- warnings and fallback decisions

## 오류 처리 정책

오류는 가능한 한 복구 가능한 형태로 다룬다.

- API capability 부족은 실패가 아니라 mode downgrade 후보로 처리한다.
- `v4-incremental` 불가 시 `cold-export` 가능 여부를 제시한다.
- `legacy-cbt` 실패 시 자동으로 증분 성공처럼 처리하지 않는다.
- final sync 실패 시 target VM define/start를 중단한다.
- source VM 삭제나 원본 snapshot 삭제 같은 위험 작업은 자동 수행하지 않는다.

## GitHub Actions 정책

빌드와 패키징 검증은 GitHub Actions에서 수행한다. 로컬 빌드는 수행하지 않는다.

초기 CI 항목은 다음을 목표로 한다.

- shell syntax check
- shellcheck
- Markdown lint
- JSON schema validation
- unit test for manifest helpers
- fixture-based API response parsing test
- package metadata validation

로컬에서는 다음만 허용한다.

- 파일 내용 확인
- git 상태 확인
- 문서 한글 표시 확인
- shell script 문법 검토 수준의 비파괴 검사

## 구현 단계

### 1단계: 골격 생성

- `bin/ablestack_n2k.sh` 생성
- `lib/n2k/` 기본 모듈 생성
- `preflight`, `plan`, `status` 명령 먼저 구현
- manifest v1 스키마 초안 작성
- GitHub Actions 기반 기본 검증 추가

### 2단계: 인벤토리 수집

- Prism Central 접속 정보 처리
- VM 조회
- CPU, memory, NIC, firmware, guest OS 정보 수집
- disk 목록과 size 수집
- target map 처리

### 3단계: cold-export 구현

- 전체 디스크 복제 경로 구현
- file/block/rbd target 지원
- libvirt define-only 지원
- Linux/Windows bootstrap 경로 연결

### 4단계: v4-incremental PoC

- recovery point 생성
- disk recovery point 식별
- changed regions 조회
- changed regions 정규화
- patch apply 연동
- final sync 검증

### 5단계: legacy fallback 검토

- legacy changed-region 기능 탐지
- 사용 가능 환경과 제한 사항 문서화
- `--allow-experimental` 보호 장치 적용
- 실패 시 cold-export fallback 처리

### 6단계: 운영성 강화

- resume 안정화
- cleanup 안전성 강화
- status 요약 강화
- fleet 실행 검토
- 예제와 runbook 작성

## 주요 리스크

| 리스크 | 영향 | 대응 |
| --- | --- | --- |
| Recovery Point disk read path 불명확 | 증분/전체 복제 모두 영향 | PoC 최우선 검증 |
| legacy API 환경 차이 | 구버전 지원 불안정 | experimental 모드와 cold fallback |
| Windows boot failure | cutover 실패 | WinPE bootstrap과 virtio driver 정책 |
| Secure Boot/TPM 차이 | Windows 11 등 영향 | source inventory 보존 및 명시 옵션 |
| snapshot/recovery point cleanup 위험 | 원본 손상 가능성 | 기본 보존, 명시 옵션 필요 |
| 장시간 cold export | 긴 다운타임 | 사전 예상 시간 출력 |

## 성공 기준

초기 성공 기준은 다음과 같다.

- 구버전 Nutanix 환경에서도 `preflight`가 가능한 마이그레이션 경로를 제시한다.
- `cold-export` 모드로 VM 1대를 ABLESTACK KVM에 define할 수 있다.
- v4 환경에서는 Recovery Point 기반 changed regions를 조회할 수 있다.
- target storage `file`, `block`, `rbd` 중 최소 `file/qcow2`가 동작한다.
- 모든 실행 상태가 manifest와 events log에 남는다.
- 빌드와 검증은 GitHub Actions에서 수행된다.

## 참고 자료

- Nutanix v4 API Introduction: https://www.nutanix.dev/api-reference-v4/
- Nutanix REST API and SDK Versions: https://www.nutanix.dev/api-versions/
- Nutanix v4 Changed Blocks Tracking and Changed Regions Tracking: https://www.nutanix.dev/2025/01/15/nutanix-v4-disaster-recovery-api-series-part-2-changed-blocks-tracking-cbt-and-changed-regions-tracking-crt/
- Nutanix Legacy API deprecation announcement summary: https://www.nutanix.com/blog/announcing-the-v4-api-and-sdk-general-availability-in-pc-2024-3-aos-7-0
