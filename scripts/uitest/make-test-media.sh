#!/usr/bin/env bash
#
# Builds the tagged audio the UI tests expect: a small drop-zone album and a
# deliberately multi-megabyte "remote" library, so a ranged tag read is
# visibly a fraction of a file.
#
# Needs ffmpeg and flac (metaflac). Output: $1 (default build/uitest-media).
set -euo pipefail

OUT="${1:-build/uitest-media}"
command -v ffmpeg >/dev/null   || { echo "ffmpeg not found" >&2; exit 1; }
command -v metaflac >/dev/null || { echo "metaflac not found (brew install flac)" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/local/Ada Lovelace/Analytical Engine" \
         "$OUT/remote/Nova Drift/Deep Field" \
         "$OUT/remote/Nova Drift/Signal Lost"

# Flat colour covers, so artwork in a screenshot is unmistakably per-album.
python3 - "$OUT" <<'PY'
import struct, sys, zlib
from pathlib import Path
def png(path, rgb):
    w = h = 300
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )
out = sys.argv[1]
png(f"{out}/cover-local.png", (78, 36, 155))
png(f"{out}/cover-remote.png", (20, 120, 140))
PY
ffmpeg -y -i "$OUT/cover-local.png"  "$OUT/cover-local.jpg"  2>/dev/null
ffmpeg -y -i "$OUT/cover-remote.png" "$OUT/cover-remote.jpg" 2>/dev/null

ffmpeg -y -f lavfi -i "sine=frequency=440:duration=4" -c:a pcm_s16le "$OUT/tone.wav" 2>/dev/null
# Pink noise defeats FLAC compression, so each remote track stays ~3 MB.
ffmpeg -y -f lavfi -i "anoisesrc=d=45:c=pink:a=0.4" -ac 2 -ar 44100 -c:a pcm_s16le "$OUT/noise.wav" 2>/dev/null

flac_track() {
  local src="$1" out="$2" title="$3" artist="$4" album="$5" num="$6" art="$7"
  ffmpeg -y -i "$src" -c:a flac -compression_level 0 \
    -metadata TITLE="$title" -metadata ARTIST="$artist" -metadata ALBUM="$album" \
    -metadata TRACKNUMBER="$num" -metadata DATE="2026" -metadata GENRE="Electronic" \
    "$out" 2>/dev/null
  metaflac --import-picture-from="$art" "$out"
}

L="$OUT/local/Ada Lovelace/Analytical Engine"
flac_track "$OUT/tone.wav" "$L/01 First Program.flac"     "First Program"     "Ada Lovelace" "Analytical Engine" 1 "$OUT/cover-local.jpg"
flac_track "$OUT/tone.wav" "$L/02 Bernoulli Numbers.flac" "Bernoulli Numbers" "Ada Lovelace" "Analytical Engine" 2 "$OUT/cover-local.jpg"
# One non-FLAC file, so the MP3/AVAsset path is covered too.
ffmpeg -y -i "$OUT/tone.wav" -c:a libmp3lame \
  -metadata title="Punched Card" -metadata artist="Ada Lovelace" \
  -metadata album="Analytical Engine" -metadata track="3" \
  "$L/03 Punched Card.mp3" 2>/dev/null

D="$OUT/remote/Nova Drift/Deep Field"
S="$OUT/remote/Nova Drift/Signal Lost"
flac_track "$OUT/noise.wav" "$D/01 Event Horizon.flac" "Event Horizon" "Nova Drift" "Deep Field"  1 "$OUT/cover-remote.jpg"
flac_track "$OUT/noise.wav" "$D/02 Redshift.flac"      "Redshift"      "Nova Drift" "Deep Field"  2 "$OUT/cover-remote.jpg"
flac_track "$OUT/noise.wav" "$D/03 Parallax.flac"      "Parallax"      "Nova Drift" "Deep Field"  3 "$OUT/cover-remote.jpg"
flac_track "$OUT/noise.wav" "$S/01 Carrier Wave.flac"  "Carrier Wave"  "Nova Drift" "Signal Lost" 1 "$OUT/cover-remote.jpg"
flac_track "$OUT/noise.wav" "$S/02 Static Bloom.flac"  "Static Bloom"  "Nova Drift" "Signal Lost" 2 "$OUT/cover-remote.jpg"

rm -f "$OUT/tone.wav" "$OUT/noise.wav" "$OUT"/cover-*.png
echo "drop-zone album : $(find "$OUT/local" -type f | wc -l | tr -d ' ') files"
echo "remote library  : $(find "$OUT/remote" -type f | wc -l | tr -d ' ') files, $(du -sh "$OUT/remote" | cut -f1)"
