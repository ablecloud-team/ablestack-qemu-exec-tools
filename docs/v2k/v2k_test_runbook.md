# ablestack_v2k Test Runbook

This document summarizes the recommended validation order for `ablestack_v2k`.

## Before Testing

1. Prepare compatibility assets in `assets/compat/<profile>/...`
2. Confirm installer visibility:

```bash
bin/v2k_test_install.sh --list-profiles
```

3. Install and validate profiles:

```bash
sudo bin/v2k_test_install.sh --install-assets --install-profile all
sudo bin/v2k_test_install.sh --skip-install --validate-profile all
```

## Minimum Validation Sequence

For a real VMware VM:

```bash
ablestack_v2k init ...
ablestack_v2k --workdir <workdir> cbt status
ablestack_v2k --workdir <workdir> cbt enable
ablestack_v2k --workdir <workdir> snapshot base
ablestack_v2k --workdir <workdir> sync base --jobs 1
```

## Compatibility Validation

After `init --compat-profile auto`, inspect:

```bash
jq '.source.compat' <workdir>/manifest.json
```

Expected fields:

- `requested_profile`
- `selected_profile`
- `detected_vcenter_version`
- `tools.govc_bin`
- `tools.python_bin`
- `tools.vddk_libdir`

## Split / Full Run Validation

Recommended sequence for one test VM:

1. `run --split phase1`
2. `run --split phase2`
3. restore source VM power state if needed
4. `run` full

Use separate workdirs and destination paths for phase-run and full-run tests.

## Cloud Multi-NIC Validation

Run the fixture smoke checks:

```bash
tests/v2k_inventory_disk_order_smoke.sh
tests/v2k_cloud_nic_mapping_smoke.sh
```

For a real two-NIC VMware VM:

1. Confirm inventory contains both NIC keys, labels, VMware networks, and MACs.
2. Select two unique Cloud networks in wizard mode.
3. Confirm `target.cloud.nic_mappings` contains two ordered mappings.
4. Run Cloud cutover with the VM initially deployed stopped.
5. Compare `runtime.cloud.nic_verification.actual_nics` with the source MACs and
   selected network IDs.
6. Confirm the first mapping is the default NIC and the VM starts only after
   verification succeeds.

Negative cases must fail before VM start:

- fewer or more Cloud networks than source NICs
- duplicate Cloud network IDs
- duplicate, invalid, or multicast source MAC
- Cloud-side MAC replacement caused by a conflict

## Useful Commands

```bash
ablestack_v2k --workdir <workdir> status
tail -n 100 <workdir>/events.log
jq '.phases, .runtime, .source.compat' <workdir>/manifest.json
```

## What Counts As Success

- installer validation passes for all required profiles
- `init --compat-profile auto` selects the expected profile
- `cbt enable`, `snapshot base`, and `sync base` succeed
- split/full `run` tests complete with the expected phase markers
- Cloud multi-NIC mappings preserve every selected network/MAC pair
