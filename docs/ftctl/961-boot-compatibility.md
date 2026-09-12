# Issue 961: boot compatibility evidence

Keep source_hardware_fingerprint v2 unchanged. Runtime status additionally emits source_boot_hardware_version=1 and source_boot_hardware, an allowlisted projection of profile source hardware excluding compute/performance details. Cloud performs normalization and comparison. This is profile correlation evidence, not proof of target XML or successful guest boot. Existing profiles are supported without rewriting them. Missing/deleted profiles emit an empty object; release tombstone reconstruction remains valid.

Implementation refinement from the issue design: transmit inspectable boot fields instead of introducing a second cross-language hash. The consumer compares normalized fields; existing full hashes remain diagnostic and legacy fallback. Unknown evidence never becomes fabricated proof. No worker placement, authority, artifact, lifecycle or scheduler contract changes. Branch release gates include the new boot smoke and existing release/action tests before packaging.

## Build and paired deployment evidence

Code commit 292c35f84299ad382d6c26fcaaa57cf7baf18a6a; Actions https://github.com/dhslove/ablestack-qemu-exec-tools/actions/runs/34356201076 succeeded. RPM SHA256 732123ea17f21073450a8efb41a2568f282d5198cdd29c2d9e098e1e9bd63b95. Installed on source 13 and target 31 compute hosts after package verification, preserving existing VM inventory. Installed dr_runtime.sh SHA256 cd57be9e85620a7160ec27aa060e31284e37a9baecb0382f1bceac72faa4f98a.

Cloud paired branch codex/fix-961-boot-compatibility documents physical UI evidence in docs/ftctl/issue-961-boot-compatibility.md. Verified qcow2-to-qcow2 synchronization with target tuning differences, required UEFI mismatch rejection, recovery, test VM boot and cleanup. A separate UI stop/edit/start proved the test VM boots without iothreads and with io=threads; direct QGA and root/EFI/data filesystem evidence corroborate this. This is not a claim that all storage/provider full-chain paths were physically rerun. Existing automated release tombstone and lifecycle gates passed before RPM generation.
