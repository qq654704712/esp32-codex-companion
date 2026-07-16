#!/usr/bin/env python3
"""Continuously mirror an ESP32 USB-Serial/JTAG port to stdout."""

import sys
import serial


def main() -> None:
    port = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbmodem4101"
    with serial.Serial(port, 115200, timeout=0.25) as device:
        print("CAPTURE_READY", flush=True)
        while True:
            data = device.read(2048)
            if data:
                print(data.decode("utf-8", errors="replace"), end="", flush=True)


if __name__ == "__main__":
    main()
