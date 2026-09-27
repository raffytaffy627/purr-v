#!/usr/bin/env python3
"""flash.py - send a program to purr-V over USB-UART (no re-synthesis!)

    python tools/flash.py COM5 build/parking.bin
    python tools/flash.py /dev/ttyUSB1 build/dino.bin --monitor

the FPGA's bootloader sees "PURR", holds the CPU in reset, writes the program
into RAM, checks the checksum, and restarts the CPU. --monitor keeps the port
open afterwards and prints whatever the program sends back :3
(needs: pip install pyserial)
"""

import argparse
import struct
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("need pyserial:  pip install pyserial")

RAM_BYTES = 16 * 1024


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port")
    ap.add_argument("bin")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--monitor", action="store_true", help="print UART output after flashing")
    args = ap.parse_args()

    data = open(args.bin, "rb").read()
    if len(data) > RAM_BYTES:
        sys.exit(f"{len(data)} bytes won't fit in {RAM_BYTES} bytes of RAM :o")

    packet = b"PURR" + struct.pack("<I", len(data)) + data + bytes([sum(data) & 0xFF])

    with serial.Serial(args.port, args.baud, timeout=2) as port:
        port.reset_input_buffer()
        t0 = time.time()
        port.write(packet)
        port.flush()

        # skip whatever the old program was printing until we see the reply
        deadline = time.time() + 3 + len(packet) * 10 / args.baud
        reply = b""
        while time.time() < deadline:
            b = port.read(1)
            if b in (b"K", b"E", b"T"):
                reply = b
                break

        if reply == b"K":
            print(f"flashed {len(data)} bytes in {time.time() - t0:.2f} s, CPU restarted :3")
        elif reply == b"E":
            sys.exit("checksum mismatch :(  CPU is held in reset, try again")
        elif reply == b"T":
            sys.exit("bootloader timed out waiting for data :(  try again")
        else:
            sys.exit("no reply from the bootloader :(  right port? is the bitstream loaded?")

        if args.monitor:
            print("--- monitor (ctrl+c to quit) ---")
            try:
                while True:
                    chunk = port.read(port.in_waiting or 1)
                    if chunk:
                        sys.stdout.write(chunk.decode("utf-8", "replace").replace("\r", ""))
                        sys.stdout.flush()
            except KeyboardInterrupt:
                pass


if __name__ == "__main__":
    main()
