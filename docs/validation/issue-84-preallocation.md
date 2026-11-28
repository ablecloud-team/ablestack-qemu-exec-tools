# 이슈 #84 preallocation 구현 검증

- 검증일: 2026-11-26
- 기준: upstream main `4b62759a2f82d96fbc26c12710131db9049e6bc6`
- 환경: RockyLinux 9.7 WSL, ext4, QEMU 9.1.0, libnbd/nbdcopy 1.20.3
- 구현/운영 계약: [대상 이미지 preallocation](../v2k_n2k_preallocation.md)

## 전용 검증

`python3 tests/image_preallocation_test.py`: 14개 테스트와 하위 매트릭스 통과.

- v2k nbdcopy/convert 및 n2k convert: qcow2 네 모드·raw 세 모드의 21개 조합.
  임시 8 MiB 원본의 영(0)/비영(0) 데이터, 공백이 있는 경로를 사용했다.
  qemu-img compare로 데이터 일치를 확인하고 falloc/full은 가상 크기 이상의
  파일시스템 블록 할당, off/metadata는 sparse 동작을 확인했다.
- 실제 양쪽 wizard 함수의 대화 메뉴·Enter 기본 선택·명시값·--yes·print-command,
  raw/Cloud 파일/RBD/블록·취소·TTY 없음·legacy/저장값 재개·생성 후 충돌을 검증했다.
  원본/Cloud 조회와 run 실행 경계는 fixture/stub을 사용한다.
- 실제 run 함수에서 init 경계로 기본값·명시값 전달, init 파서에서 manifest 저장,
  독립 패키지 설치 경로의 라이브러리 로딩을 확인했다.
- ENOSPC(28), 미지원(95), 권한 오류(13)를 두 도구에 주입했다. 오류와 부분 생성
  이력이 보존되고 off 재시도·base 완료 오판정·기존 파일 덮어쓰기가 없었다.
- v2k dry-run은 이미지 및 완료 상태를 변경하지 않는다. 완료된 파일 대상 재개는
  이미지 수정 시각이 유지되어 재생성이 없음을 확인했다.

## 기존 회귀

기존 smoke 18개, n2k 전체 Shellcheck, 셸 구문 검사와 git diff --check를 통과했다.
회귀 범위는 RBD staging/NFC 재시도, v2k/n2k 컨트롤러·디스크 순서·관측 상태,
Cloud NIC/타깃 계약·CPU 속도, CBT pagination/대용량 payload, cutover/Ubuntu initramfs/
WinPE와 Cloud 인계 계약이다.

추가 Actions는 Ubuntu 24.04와 Rocky 9 컨테이너에서 전용 시험을 수행한다.
Actions 결과와 실행 링크는 PR의 최신 검증 기록을 따른다.

## 범위와 설계 보완

libnbd 1.20은 --no-truncate를 제공하지 않는다. 선할당 raw도 qemu-nbd로 내보내어
nbdcopy가 로컬 파일을 truncate할 수 없게 하고 --allocated로 할당을 유지했다.
직접 파일 --no-truncate와 같은 보존 계약을 지원 버전에서 구현한 변경이다.

이 시험은 임시 이미지와 fixture를 사용한 코드·파일시스템 검증이다. 실제 vCenter/
Nutanix 소스 VM, 실제 Cloud 저장소/GFS/NFS, 운영 호스트 배포 및 마이그레이션 E2E는
실행하지 않았다. 파일시스템 공간 확보를 하부 thin 저장소의 물리 예약으로 해석하지 않는다.
