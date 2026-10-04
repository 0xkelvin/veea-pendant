"""Inspect Pendant CDC output with bounded diagnostic commands; no reset/erase support."""
import argparse
import os
from pathlib import Path
import select
import termios
import time
import tty
import fcntl

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', default='/dev/cu.usbmodem1101')
parser.add_argument('--seconds', type=float, default=20)
parser.add_argument('--output', default='/tmp/sage-pendant-serial.bin')
parser.add_argument('--query-help', action='store_true', help='Send only the read-only Zephyr help command.')
parser.add_argument('--query', choices=['ble --help', 'ble get_name', 'ble start_advertising --help', 'device --help', 'config --help'], help='Request a known read-only diagnostic or help listing.')
parser.add_argument('--start-advertising', action='store_true', help='Ask the Pendant to start BLE advertising; does not request reset or erase.')
parser.add_argument('--restart-advertising', action='store_true', help='Stop then start BLE advertising without requesting unpair/reset/erase.')
args = parser.parse_args()
if not 0 < args.seconds <= 60:
    parser.error('Use a capture duration between 0 and 60 seconds.')
if sum([args.query_help, bool(args.query), args.start_advertising, args.restart_advertising]) > 1:
    parser.error('Choose only one diagnostic command.')

descriptor = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
original = None
received = bytearray()
query = ((args.query or 'help') + '\r').encode() if args.query or args.query_help else b''
if args.start_advertising:
    query = b'ble start_advertising\r'
if args.restart_advertising:
    query = b'ble stop_advertising\rble start_advertising\r'
try:
    fcntl.ioctl(descriptor, termios.TIOCEXCL)
    original = termios.tcgetattr(descriptor)
    settings = termios.tcgetattr(descriptor)
    tty.cfmakeraw(settings)
    settings[2] |= termios.CLOCAL | termios.CREAD
    settings[2] &= ~termios.HUPCL
    settings[4] = settings[5] = termios.B115200
    termios.tcsetattr(descriptor, termios.TCSANOW, settings)
    if query:
        os.write(descriptor, query)
    deadline = time.monotonic() + args.seconds
    while time.monotonic() < deadline and len(received) < 65536:
        readable, _, _ = select.select([descriptor], [], [], min(1, max(0, deadline - time.monotonic())))
        if readable:
            chunk = os.read(descriptor, min(4096, 65536 - len(received)))
            if chunk:
                received.extend(chunk)
finally:
    if original is not None:
        termios.tcsetattr(descriptor, termios.TCSANOW, original)
    os.close(descriptor)

output = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(output, 'wb') as stream:
    stream.write(received)
print(f'Received {len(received)} bytes from {args.port}; transmitted {len(query)} bytes.')
if received:
    print(repr(received[:8000].decode('utf-8', errors='replace')))
print(f'Capture saved to {Path(args.output)}')
