import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("select_device", Path(__file__).parents[1] / "select_device.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

HARDWARE_UDID = "12345678-1234567890ABCDEF"
COREDEVICE_ID = "11111111-2222-3333-4444-555555555555"


def device(udid=HARDWARE_UDID, identifier=COREDEVICE_ID, reality="physical", state="connected", legacy=False):
    hardware = {"udid": udid, "reality": reality, "deviceType": "iPhone", "platform": "iOS"}
    connection = {"pairingState": "paired", "state": state}
    if legacy:
        connection["tunnelState"] = connection.pop("state")
        return {"identifier": identifier, "hardwareProperties": hardware, "connectionProperties": connection}
    return {"identifier": identifier, "properties": {"hardware": hardware, "connection": connection}}


def inventory(*devices):
    return {"result": {"devices": list(devices)}}


class DeviceSelectionTests(unittest.TestCase):
    def test_24_hex_digit_hardware_udid_works_without_deprecated_fields(self):
        self.assertEqual(module.select_device(inventory(device())), HARDWARE_UDID)

    def test_xcode_26_legacy_schema_remains_supported(self):
        self.assertEqual(module.select_device(inventory(device(legacy=True))), HARDWARE_UDID)

    def test_connected_simulator_cannot_replace_physical_phone(self):
        fake = device(udid="SIMULATOR-ID", reality="simulated")
        self.assertEqual(module.select_device(inventory(fake, device())), HARDWARE_UDID)
        with self.assertRaisesRegex(ValueError, "No connected"):
            module.select_device(inventory(fake))

    def test_multiple_devices_require_selection(self):
        devices = inventory(device(), device(udid="SECOND-DEVICE", identifier="SECOND-COREDEVICE"))
        with self.assertRaisesRegex(ValueError, "Multiple physical"):
            module.select_device(devices)
        self.assertEqual(module.select_device(devices, device_udid=HARDWARE_UDID), HARDWARE_UDID)
        self.assertEqual(module.select_device(devices, device_id=COREDEVICE_ID), HARDWARE_UDID)
        self.assertEqual(module.select_device(devices, device_id=HARDWARE_UDID), HARDWARE_UDID)

    def test_disconnected_or_unpaired_device_cannot_be_selected(self):
        unpaired = device()
        unpaired["properties"]["connection"]["pairingState"] = "unpaired"
        for candidate in (device(state="disconnected"), unpaired):
            with self.assertRaisesRegex(ValueError, "Requested device"):
                module.select_device(inventory(candidate), device_udid=HARDWARE_UDID)

    def test_conflicting_explicit_selectors_fail(self):
        devices = inventory(device(), device(udid="SECOND-DEVICE", identifier="SECOND-COREDEVICE"))
        with self.assertRaisesRegex(ValueError, "Requested device"):
            module.select_device(devices, device_udid=HARDWARE_UDID, device_id="SECOND-COREDEVICE")

    def test_duplicate_connections_to_same_phone_do_not_create_ambiguity(self):
        self.assertEqual(module.select_device(inventory(device(), device(state="available"))), HARDWARE_UDID)

    def test_missing_inventory_fails_clearly(self):
        with self.assertRaisesRegex(ValueError, "inventory"):
            module.select_device({"info": {"outcome": "failed"}})


if __name__ == "__main__":
    unittest.main()
