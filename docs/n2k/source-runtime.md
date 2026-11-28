# Windows 원본 수집용 Python 환경

Windows 원본의 설정 수집은 인증한 WinRM 세션으로 실행한다. Rocky/ABLESTACK의 구형 `requests-ntlm` 패키지는 OpenSSL 3에서 `unsupported hash type md4` 오류가 발생할 수 있다. 전용 Python 환경을 사용하면 호스트의 Python 패키지와 암호 정책을 유지할 수 있다.

원본 수집 환경에는 시스템의 `python3-winrm`, `python3-paramiko`, `python3-pyyaml`과 Python venv/pip가 필요하다. 인터넷이 가능한 준비 장비에서 다음 wheel을 확보한 뒤 작업 호스트로 전달한다.

```bash
python3 -m pip download --no-deps --dest source-wheels \
  pywinrm==0.5.0 requests-ntlm==1.3.0 pyspnego==0.12.0
```

작업 호스트에서 다음 명령을 실행한다. 설치기는 wheel 세 개의 고정 SHA-256을 모두 확인한 다음, 시스템 패키지를 공유하는 전용 환경을 만들고 인터넷 접속 없이 설치·검증한다.

```bash
python3 /usr/local/lib/ablestack-qemu-exec-tools/n2k/install_source_runtime.py \
  --wheel-dir /path/to/source-wheels
```

검증한 환경은 `n2k/runtime/bin/python`에 생성되며 n2k가 자동 선택한다. 운영자가 별도로 관리하는 환경은 `N2K_PYTHON_BIN`으로 지정할 수 있다. 이 환경에는 인증 정보를 저장하지 않는다. Prism/게스트 인증은 기존 런타임 환경변수나 대화형 입력으로 전달한다.
