# v2k vSphere 6.x+ Compatibility Implementation Plan

## Goal

Refactor `ablestack_v2k` so that VMware `vCenter 6.0` and later releases can be handled safely by selecting an isolated compatibility profile for:

- `govc`
- `pyVmomi`
- `VDDK`

The selected profile must remain stable for the entire lifecycle of a run, including `split=phase1/phase2`, `--resume`, and background execution.

## Target Outcome

After this work:

- the runtime no longer depends on a single globally installed `govc`
- the runtime no longer depends on the system `python3` for VMware API calls
- `VDDK_LIBDIR` is resolved from a selected compatibility profile, not a single fixed path
- the selected profile is saved in `manifest.json` and reused on resume
- installers/package layouts support multiple coexisting VMware compatibility profiles

## Profile Model

Each profile should be self-contained under a compatibility root, for example:

`/usr/share/ablestack/v2k/compat/<profile-id>/`

Recommended initial profile IDs:

- `vsphere60`
- `vsphere67`
- `vsphere80`

Each profile should contain:

- `bin/govc`
- `venv/bin/python3`
- `vddk/`
- `profile.json`

Minimum `profile.json` fields:

- `id`
- `label`
- `supported_vcenter`
- `govc_version`
- `pyvmomi_version`
- `vddk_version`
- `selection_rules`

## Work Breakdown

### Phase 1. Runtime Compatibility Layer

Create a new runtime layer that owns:

- profile discovery
- version detection
- profile selection
- activation of `govc`, `python3`, `VDDK_LIBDIR`
- manifest persistence
- resume-time restoration

Deliverables:

- new `compat.sh`
- new wrapper functions for govc/python
- new manifest schema fields for compatibility state

### Phase 2. CLI and Init Flow Integration

Integrate compatibility selection into `run` and `init`.

Deliverables:

- `--compat-profile <id|auto>`
- auto-detect source vCenter version
- write selected profile metadata to manifest/workdir
- restore the same profile during resume

### Phase 3. Replace Direct Tool Calls

Remove all direct dependence on global `govc` and `python3`.

Deliverables:

- all VMware-related shell calls go through wrapper functions
- `vmware_changed_areas.py` and helper Python invocations run through selected profile python

### Phase 4. Installer and Packaging Refactor

Change install layout from single global tool placement to multi-profile layout.

Deliverables:

- installer supports profile-specific asset installation
- packaged assets are stored by profile
- docs explain install and selection model

### Phase 5. Validation Matrix

Add smoke-test coverage around profile selection and resume behavior.

Deliverables:

- profile selection tests
- manifest persistence tests
- split-run compatibility tests
- operator runbook updates

## File-by-File TODO

### 1. `bin/ablestack_v2k.sh`

Role:

- CLI entrypoint
- global env resolution
- usage/help text

TODO:

- source new `lib/.../v2k/compat.sh`
- add CLI option `--compat-profile <id|auto>`
- document new env vars:
  - `V2K_COMPAT_PROFILE`
  - `V2K_COMPAT_ROOT`
  - `V2K_GOVC_BIN`
  - `V2K_PYTHON_BIN`
- replace current single-path VDDK resolution with compatibility-aware resolution
- ensure debug output can print selected profile and resolved tool paths

### 2. `lib/v2k/compat.sh` (new)

Role:

- compatibility profile engine

TODO:

- implement compatibility root discovery
- implement profile metadata loading from `profile.json`
- implement vCenter version detection
- implement auto profile selection
- implement manual profile validation
- export resolved runtime variables
- provide wrappers:
  - `v2k_govc`
  - `v2k_python`
  - `v2k_require_compat_profile`
- provide manifest helper functions for profile save/load
- provide operator-facing error messages when no valid profile matches

### 3. `lib/v2k/engine.sh`

Role:

- init/sync/cutover command execution
- manifest lifecycle

TODO:

- parse and preserve `--compat-profile`
- during `init`, detect or resolve profile before VMware inventory calls
- save selected profile to manifest
- on `resume`, reload profile from manifest before any VMware call
- replace direct thumbprint/runtime assumptions with profile-aware values
- ensure all phases use the same resolved `govc`/`python3`/`VDDK_LIBDIR`
- emit events showing selected profile and detected vCenter version

### 4. `lib/v2k/orchestrator.sh`

Role:

- `run` orchestration
- workdir state handling

TODO:

- persist compatibility selection alongside `govc.env` and `vddk.cred`
- phase2 auto-discovery must also restore selected compatibility profile
- when `split=phase2`, fail fast if profile metadata is missing or incompatible
- add compatibility profile info to run/resume logging

### 5. `lib/v2k/manifest.sh`

Role:

- manifest construction and mutation

TODO:

- extend schema with compatibility block under `source` or `runtime`
- add getters/setters for:
  - selected profile id
  - detected vCenter version
  - resolved tool paths
  - resolved VDDK libdir
- update manifest init payload to include compatibility metadata
- update status summary helpers to expose compatibility profile

Recommended manifest shape:

```json
{
  "source": {
    "compat": {
      "requested_profile": "auto",
      "selected_profile": "vsphere60",
      "detected_vcenter_version": "6.0.0",
      "tools": {
        "govc_bin": "/usr/share/ablestack/v2k/compat/vsphere60/bin/govc",
        "python_bin": "/usr/share/ablestack/v2k/compat/vsphere60/venv/bin/python3",
        "vddk_libdir": "/usr/share/ablestack/v2k/compat/vsphere60/vddk"
      }
    }
  }
}
```

### 6. `lib/v2k/vmware_govc.sh`

Role:

- VMware inventory and govc-based operations

TODO:

- replace raw `govc` command usage with `v2k_govc`
- add a helper to query vCenter version via selected govc/runtime
- keep behavior compatible across older govc builds where flags differ
- ensure help/feature probing remains wrapper-based

### 7. `lib/v2k/transfer_base.sh`

Role:

- base sync through VDDK + govc

TODO:

- replace `command -v govc` checks with compatibility wrapper validation
- use profile-selected `VDDK_LIBDIR`
- emit selected compatibility profile in logs for transfer diagnostics
- avoid implicit fallback to global tools

### 8. `lib/v2k/transfer_patch.sh`

Role:

- incremental/final sync via pyVmomi + VDDK

TODO:

- replace `command -v python3` and direct `python3` calls with `v2k_python`
- replace `command -v govc` checks with compatibility wrapper validation
- ensure `vmware_changed_areas.py` runs with profile-selected python venv
- log compatibility profile and runtime paths into patch logs

### 9. `lib/v2k/vmware_changed_areas.py`

Role:

- pyVmomi-based CBT changed-area query

TODO:

- keep script import-compatible with profile-selected pyVmomi
- avoid assuming system-wide pyVmomi installation
- add clearer error text for SDK/version mismatch conditions
- optionally expose API version in debug output if useful for diagnosis

### 10. `bin/v2k_test_install.sh`

Role:

- dependency installer/checker

TODO:

- replace single global install model with profile-aware install model
- accept profile-specific asset inputs
- install `govc` into profile-local `bin/`
- install pyVmomi into profile-local `venv/`
- install VDDK into profile-local `vddk/`
- stop creating one global `/usr/local/bin/govc`
- stop relying on one global `/opt/vmware-vix-disklib-distrib` symlink as the primary model
- add validation for each installed profile
- add command to list installed profiles

Suggested new options:

- `--install-profile <id>`
- `--compat-root <path>`
- `--list-profiles`
- `--validate-profile <id>`

### 11. `rpm/ablestack_v2k.spec`

Role:

- RPM packaging metadata

TODO:

- package compatibility runtime assets layout
- add profile metadata files if they are distributed in RPM
- ensure package description reflects multi-profile runtime
- avoid documenting single global govc/VDDK install paths as the only supported mode

### 12. `.github/workflows/build.yml`

Role:

- packaging and release assembly

TODO:

- produce release assets grouped by compatibility profile
- build offline wheels per profile when needed
- package profile metadata and install layout
- update test/install steps to validate multiple profiles, not one global runtime

### 13. `docs/v2k/v2k_cli_guide.md`

TODO:

- document `--compat-profile`
- document auto selection behavior
- document resume behavior and profile pinning
- document new env vars and profile override behavior

### 14. `docs/v2k/v2k_migration.md`

TODO:

- explain why compatibility profiles are required
- describe version family mapping
- explain how `govc`, `pyVmomi`, and `VDDK` are isolated per profile

### 15. `docs/v2k/v2k_test_runbook.md`

TODO:

- add profile install steps
- add validation checklist per VMware version family
- add split-run/resume validation steps

### 16. `examples/v2k/runbook.md`

TODO:

- add examples using `--compat-profile auto`
- add examples using forced profile selection
- add troubleshooting section for profile mismatch

## Implementation Order

Recommended order:

1. Add `compat.sh`
2. Extend manifest schema and helpers
3. Wire profile selection into `bin/ablestack_v2k.sh` and `engine.sh`
4. Replace direct `govc`/`python3` calls
5. Update `orchestrator.sh` resume handling
6. Refactor installer and packaging
7. Update docs and runbooks

## Acceptance Criteria

The feature is ready when all of the following are true:

- `init --compat-profile auto` selects a profile and records it in manifest
- `run --split phase1` and `run --split phase2` reuse the same profile
- `--resume` reuses the same profile without falling back to global tools
- no VMware API path depends on system-global `govc` or `python3`
- multiple profiles can coexist on the same host
- operator can inspect selected profile from `status`

## Test Matrix

Minimum validation matrix:

- `vCenter 6.0` with `vsphere60`
- `vCenter 6.7` with `vsphere67`
- `vCenter 7.0` with `vsphere80` or validated equivalent
- `vCenter 8.x` with `vsphere80`

Minimum scenario coverage:

- `init`
- `cbt enable`
- `snapshot base`
- `sync base`
- `snapshot incr`
- `sync incr`
- `run --split phase1`
- `run --split phase2`
- `status`

## Risks To Watch

- older `govc` builds may not support the same flags or JSON structures
- `pyVmomi` behavior can vary across old SOAP endpoints and TLS defaults
- `nbdkit-vddk-plugin` may behave differently across VDDK major lines
- mixing one profile in phase1 and another in phase2 must be explicitly prevented
- profile auto-selection must be deterministic and observable

