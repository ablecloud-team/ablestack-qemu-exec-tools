#!/bin/bash
#
# vm_exec_example.sh - Example usage script for vm_exec.sh
#
# Copyright 2025 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# 이 스크립트는 vm_exec 명령의 사용 예시를 보여줍니다.

echo "▶ Linux VM: ps aux 출력 파싱 (table + headers + json)"
vm_exec -l ubuntu-vm ps aux --table --headers "USER,PID,%CPU,%MEM,COMMAND" --json

echo ""
echo "▶ Windows VM: tasklist 출력 파싱"
vm_exec -w win10-vm tasklist --table --headers "Image Name,PID,Session Name,Session#,Mem Usage" --json

echo ""
echo "▶ 스크립트 파일 실행 예시 (serial)"
vm_exec -l centos-vm --file ./examples/commands.txt

echo ""
echo "▶ 스크립트 파일 실행 예시 (parallel)"
vm_exec -l centos-vm --file ./examples/commands.txt --parallel
