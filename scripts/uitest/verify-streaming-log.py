#!/usr/bin/env python3
"""Prove the UI streaming step did not eagerly fetch the whole track."""

import json
import sys


path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    entries = [json.loads(line) for line in handle if line.strip()]

track = "/Nova Drift/Deep Field/01 Event Horizon.flac"
started = False
ranges = []

for entry in entries:
    if entry.get("path") != track or entry.get("method") != "GET":
        continue
    if entry.get("range") == "bytes=0-1" and entry.get("status") == 206:
        started = True
        continue
    if not started:
        continue
    if entry.get("status") == 200:
        break
    if entry.get("status") == 206:
        ranges.append(entry)

if not ranges:
    raise SystemExit("streaming log contains no playback ranges")
if any(int(entry.get("bytes_sent", 0)) > 524_288 for entry in ranges):
    raise SystemExit("streaming returned a playback chunk larger than 512 KiB")

# The 45-second fixture buffers about 15 seconds in three chunks. Every later
# chunk represents roughly seven seconds of media and must not arrive as part
# of the initial network-speed burst.
for previous, current in zip(ranges[2:], ranges[3:]):
    delay = float(current["time"]) - float(previous["time"])
    if delay < 4:
        raise SystemExit(f"streaming fetched a read-ahead chunk after only {delay:.2f}s")

total = sum(int(entry.get("bytes_sent", 0)) for entry in ranges)
print(f"streaming served {len(ranges)} paced ranges ({total} bytes)")
