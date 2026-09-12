# VMware snapshot chain 읽기 수정 (#971 검증 차단 / #1003)

DR full-seed/full-reseed와 CBT patch 모두 nbdkit VDDK `single-link=false`로 전체 부모 체인을 연다. capture별 VMware snapshot/VM/device-key 재해석과 read-only, CBT extent 선택, 대상 writer/authority 계약은 유지한다. 레거시 v2k 및 다른 DR 경로는 변경하지 않는다.

## 실측 근거
2026-09-10 32.2, nbdkit1.38.5, 기존 외부 snapshot62747의 test1-000004.vmdk를 읽기 전용으로 비교. 같은 snapshot/VM/path/TLS 조건에서 single-link=true 첫1MiB는 전부0, GPT 없음; false는 nonzero188bytes, EFI PART, SHA e67cf75fa57b9c5b05943804e8a0420729d92573089abf671156ea5b10da3f81. 블록 map도 true present=false/data=false, false present=true/data=true.

full-reseed Run441은100GiB 전송 성공이나 Test442 실패, clone 첫1MiB가0. 이전 증분Test440은 XFS zeroed log/LSN 불일치. 원본 변경 여부 추정이 아니라 같은 immutable snapshot의 옵션 비교로 데이터 누락을 확인했다.

공식 옵션 계약: https://libguestfs.org/nbdkit-vddk-plugin.1.html

## 검증 계획
사용자 지시에 따라 셸 모듈 시험은 RPM 재빌드 없이 변경 파일을 직접 배포한다. 파일 배포 후 실제 full-reseed, VMware 대상 OS/virtio 부팅(QGA 양단 제외), RUNNING cleanup 복원 및 PAUSED 유지, source-vCenter 단절 테스트를 재검증한다. 실패경로 잔여 자원/HELD 복원은 별도 #1004이며 정상경로 PASS와 구분한다. 기존 외부 스냅샷은 보존한다.


## 파일 배포 및 모듈 시험
사용자 요청으로 GitHub Actions34449382529 취소 요청 후 파일 직접 배포로 전환. 신규 RPM 릴리즈 PASS를 주장하지 않는다.
32.1/2/3에 dr_vmware_mover.sh 한 파일 배포, 기존 파일은 /root/issue1003-file-20260910/dr_vmware_mover.sh.backup 보존. 설치 SHA256 0892274ffff79add112b8e27d56655599cd640eabb7cd768d44dc7c555b4005a. 셸 문법, VM UUID 목록 및 agent.properties 동일, mold-agent active 확인.
WSL 모듈 스모크: ftctl_dr_vmware_snapshot_cleanup_smoke.sh PASS, ftctl_dr_vmware_thumbprint_refresh_smoke.sh PASS. 실제 복제 nbdkit 프로세스에서 vm-4486/snapshot62786/single-link=false 확인.


## 실환경 결과
수정 후 UI Full-reseed443 SUCCEEDED. Test444 VM311 Rocky Linux10.1 로그인/virtio-scsi DRIVER_OK PASS. vCenter 단절 중 Cleanup445 성공, 연결 복구 후 별도Resume 없이 RUNNING/RESTORED 및 cycle12 CBT_INCREMENTAL 39extents/2,883,584bytes/durable16:34:47 확인. 그 증분 복제본의 Test447 VM312도 실제 OS/드라이버 PASS.
PAUSED 정리448 및 원본 단절 상태에서 source-independent Test449 VM313/cleanup450 모두 PASS, PAUSED 의도 보존. VMware 양단 QGA 미사용. 최종 시험 종료Resume451 후 RUNNING/HEALTHY/IDLE/cycle13 확인. 자세한 Run ID는 Cloud docs/ftctl/issue-988-validation.md에 기록했다.
