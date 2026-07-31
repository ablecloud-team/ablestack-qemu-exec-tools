#!/usr/bin/env python3

import importlib.util
import sys
import types
from pathlib import Path


class VirtualMachine:
    pass


class VirtualMachineSnapshot:
    pass


class Snapshot:
    pass


class ConfigInfo:
    pass


class VirtualSCSIController:
    pass


class VirtualIDEController:
    pass


class VirtualSATAController:
    pass


class VirtualNVMEController:
    pass


class VirtualDisk:
    pass


def install_pyvmomi_stubs() -> None:
    connect_module = types.ModuleType("pyVim.connect")
    connect_module.SmartConnect = lambda **_kwargs: None
    connect_module.SmartConnectNoSSL = lambda **_kwargs: None
    connect_module.Disconnect = lambda _si: None

    pyvim_module = types.ModuleType("pyVim")
    pyvim_module.connect = connect_module

    vim = types.SimpleNamespace(
        VirtualMachine=VirtualMachine,
        VirtualMachineSnapshot=VirtualMachineSnapshot,
        vm=types.SimpleNamespace(
            Snapshot=Snapshot,
            ConfigInfo=ConfigInfo,
            device=types.SimpleNamespace(
                VirtualSCSIController=VirtualSCSIController,
                VirtualIDEController=VirtualIDEController,
                VirtualSATAController=VirtualSATAController,
                VirtualNVMEController=VirtualNVMEController,
                VirtualDisk=VirtualDisk,
            ),
        ),
    )
    pyvmomi_module = types.ModuleType("pyVmomi")
    pyvmomi_module.vim = vim

    sys.modules["pyVim"] = pyvim_module
    sys.modules["pyVim.connect"] = connect_module
    sys.modules["pyVmomi"] = pyvmomi_module


def load_helper():
    root = Path(__file__).resolve().parents[1]
    path = root / "lib" / "v2k" / "vmware_changed_areas.py"
    spec = importlib.util.spec_from_file_location("v2k_vmware_changed_areas", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load helper: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Extent:
    def __init__(self, start: int, length: int):
        self.start = start
        self.length = length


class Page:
    def __init__(self, start: int, length: int, extents, change_id: str = ""):
        self.startOffset = start
        self.length = length
        self.changedArea = extents
        self.changeId = change_id


class FakeVm:
    def __init__(self, pages):
        self.pages = pages
        self.calls = []

    def QueryChangedDiskAreas(self, *, snapshot, deviceKey, startOffset, changeId):
        del snapshot, deviceKey, changeId
        self.calls.append(startOffset)
        return self.pages[startOffset]


def controller(cls, key: int, bus: int):
    value = cls()
    value.key = key
    value.busNumber = bus
    return value


def virtual_disk(key: int, controller_key: int, unit: int):
    value = VirtualDisk()
    value.key = key
    value.controllerKey = controller_key
    value.unitNumber = unit
    return value


def expect_failure(module, vm, disk, message: str) -> None:
    try:
        module._query_changed_areas(vm, Snapshot(), disk, "change-1")
    except SystemExit as exc:
        assert message in str(exc), str(exc)
    else:
        raise AssertionError(f"Expected failure containing: {message}")


def main() -> None:
    install_pyvmomi_stubs()
    module = load_helper()

    mixed_devices = [
        controller(VirtualIDEController, 200, 0),
        controller(VirtualSCSIController, 1000, 0),
        controller(VirtualSATAController, 15000, 0),
        controller(VirtualNVMEController, 31000, 0),
        virtual_disk(3000, 200, 0),
        virtual_disk(2000, 1000, 0),
        virtual_disk(16000, 15000, 0),
        virtual_disk(32000, 31000, 0),
    ]
    selectors = {
        "ide0:0": 3000,
        "scsi0:0": 2000,
        "sata0:0": 16000,
    }
    for disk_id, expected_key in selectors.items():
        selected_key, _ = module._disk_for_selector(mixed_devices, disk_id)
        assert selected_key == expected_key, (disk_id, selected_key)

        selected_key, _ = module._disk_for_selector(
            mixed_devices,
            "legacy-or-stale-address",
            str(expected_key),
        )
        assert selected_key == expected_key, (disk_id, selected_key)

    for disk_id, device_key, expected_message in (
        ("nvme0:0", "", "Unsupported disk selector"),
        ("stale-address", "32000", "Unsupported source disk controller: nvme"),
    ):
        try:
            module._disk_for_selector(mixed_devices, disk_id, device_key)
        except SystemExit as exc:
            assert expected_message in str(exc), str(exc)
        else:
            raise AssertionError("NVMe disk controller was accepted for CBT")

    selected_key, _ = module._disk_for_selector(
        mixed_devices,
        "devkey:3000",
    )
    assert selected_key == 3000, selected_key

    try:
        module._disk_for_selector(mixed_devices, "sata0:0", "99999")
    except SystemExit as exc:
        assert "device_key=99999" in str(exc), str(exc)
    else:
        raise AssertionError("Unknown immutable VMware device key was accepted")

    disk = types.SimpleNamespace(key=2000, capacityInBytes=12288)
    vm = FakeVm(
        {
            0: Page(0, 4096, [Extent(0, 512), Extent(2048, 512)], "change-2"),
            4096: Page(4096, 4096, [Extent(4096, 1024)], "change-2"),
            8192: Page(8192, 4096, [Extent(10240, 2048)], "change-2"),
        }
    )

    areas, change_id, coverage = module._query_changed_areas(
        vm, Snapshot(), disk, "change-1"
    )
    assert vm.calls == [0, 4096, 8192], vm.calls
    assert change_id == "change-2"
    assert areas == [
        {"offset": 0, "length": 512},
        {"offset": 2048, "length": 512},
        {"offset": 4096, "length": 1024},
        {"offset": 10240, "length": 2048},
    ]
    assert coverage == {
        "mode": "delta",
        "complete": True,
        "start_offset": 0,
        "end_offset": 12288,
        "disk_capacity": 12288,
        "pages": 3,
    }

    expect_failure(
        module,
        FakeVm({0: Page(0, 0, [])}),
        disk,
        "made no coverage progress",
    )
    expect_failure(
        module,
        FakeVm({0: Page(4096, 4096, [])}),
        disk,
        "non-contiguous coverage",
    )
    expect_failure(
        module,
        FakeVm({0: Page(0, 4096, [Extent(3584, 1024)])}),
        disk,
        "outside its coverage page",
    )

    print("[OK] v2k CBT pagination and fail-closed coverage validation")


if __name__ == "__main__":
    main()
