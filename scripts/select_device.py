"""Select one connected physical iOS device from devicectl's JSON inventory."""
import json
import os
import sys


def select_device(inventory, device_udid="", device_id=""):
    devices = inventory.get("result", {}).get("devices")
    if not isinstance(devices, list):
        raise ValueError("devicectl did not return a device inventory")

    candidates = set()
    for device in devices:
        properties = device.get("properties", {})
        hardware = properties.get("hardware", device.get("hardwareProperties", {}))
        connection = properties.get("connection", device.get("connectionProperties", {}))
        state = connection.get("state", connection.get("tunnelState"))
        if (hardware.get("reality") != "physical"
                or hardware.get("deviceType") not in ("iPhone", "iPad")
                or hardware.get("platform") not in ("iOS", "iPadOS")
                or connection.get("pairingState") != "paired"
                or state not in ("connected", "available")):
            continue

        udid = hardware.get("udid")
        if not isinstance(udid, str) or not udid:
            continue
        if device_udid and device_udid != udid:
            continue
        if device_id and device_id not in (udid, device.get("identifier")):
            continue
        candidates.add(udid)

    if not candidates:
        if device_udid or device_id:
            raise ValueError("Requested device is not a connected, paired physical iPhone or iPad. Check DEVICE_UDID/DEVICE_ID and trust the device.")
        raise ValueError("No connected, paired physical iPhone or iPad found. Connect, unlock, and trust your device.")
    if len(candidates) > 1:
        raise ValueError("Multiple physical devices available. Set DEVICE_UDID to the intended hardware UDID, or DEVICE_ID to its CoreDevice identifier.")
    return next(iter(candidates))


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: select_device.py <devicectl-json-file>")
    try:
        with open(sys.argv[1], encoding="utf-8") as stream:
            inventory = json.load(stream)
        selected = select_device(inventory, os.environ.get("DEVICE_UDID", ""), os.environ.get("DEVICE_ID", ""))
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from None
    print(selected)


if __name__ == "__main__":
    main()
