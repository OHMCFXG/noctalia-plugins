#!/usr/bin/env python3
"""One-shot Xiaomi MIoT plug power query. Prints one JSON object to stdout."""

from __future__ import annotations

import argparse
import json
import logging
import sys
import warnings


def emit(payload: dict) -> None:
    json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main() -> int:
    logging.disable(logging.CRITICAL)
    warnings.filterwarnings("ignore", category=FutureWarning)

    parser = argparse.ArgumentParser(description="Query live power from a Xiaomi MIoT plug.")
    parser.add_argument("--ip", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--siid", type=int, default=11)
    parser.add_argument("--piid", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()

    try:
        from miio.exceptions import DeviceException
        from miio.miot_device import MiotDevice
    except ImportError:
        emit({"ok": False, "error": "missing_miio"})
        return 2

    try:
        plug = MiotDevice(ip=args.ip, token=args.token, timeout=args.timeout)
        result = plug.get_property_by(args.siid, args.piid)
    except DeviceException:
        emit({"ok": False, "error": "offline"})
        return 1
    except Exception:
        emit({"ok": False, "error": "device"})
        return 1

    if result and isinstance(result, list) and result[0].get("code") == 0:
        emit({"ok": True, "power": result[0].get("value", 0)})
        return 0

    emit({"ok": False, "error": "device"})
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
