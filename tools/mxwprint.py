#!/usr/bin/env python3
"""Reference print to the JK01 (MXW01-class cat printer) from a Mac — the protocol the app must speak.
usage: python3 mxwprint.py "text"  [--name JK01] [--darkness 1-5] [--png out.png]
needs: pip install bleak pillow   (the printer must be awake: press its button first)
Verified on device 2026-10-15 21:34: B1 info, A7 serial, A9 ack 00, AA done after ~3 s.
Protocol learned from TiMini-Print (Apache-2.0), CatPrinterBLE and Moblin (MIT); see README Acknowledgments."""
import argparse, asyncio, sys, time
from PIL import Image, ImageDraw, ImageFont
from bleak import BleakClient, BleakScanner

SERVICE = "0000ae30-0000-1000-8000-00805f9b34fb"
AE01, AE02, AE03, AE04 = ("0000ae0%d-0000-1000-8000-00805f9b34fb" % n for n in (1, 2, 3, 4))
WIDTH = 384                      # dots per row, 48 bytes
DENSITY = (0x58, 0x5A, 0x5D, 0x5F, 0x62)   # darkness 1..5
CONNECT_INIT = bytes.fromhex("2221B10001000000FF")
GET_SERIAL = bytes.fromhex("2221A70000000000")
FINALIZE = bytes.fromhex("2221AD000100000000")
PAUSE = {bytes.fromhex(h) for h in ("AA01", "5178AE0101001070FF", "2221A800010020E0FF", "2221AE0101001070FF", "2221AE0001000000")}
RESUME = {bytes.fromhex(h) for h in ("AA00", "5178AE0101000000FF", "2221A80001003090FF", "2221AE0101000000FF", "2221AE0001001000")}

def crc8(data: bytes) -> int:            # CRC-8, poly 0x07, init 0, no reflection
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c
assert crc8(b"\x62") == 0x29

def packet(op: int, payload: bytes) -> bytes:
    return b"\x22\x21" + bytes([op, 0, len(payload) & 0xFF, len(payload) >> 8]) + payload + bytes([crc8(payload), 0xFF])

def start_print(height: int) -> bytes:   # A9 carries a literal 00 00 tail, not crc+FF
    return bytes.fromhex("2221A9000400") + height.to_bytes(2, "little") + bytes([0x30, 0x00, 0x00, 0x00])

def render(text: str, font_path="/System/Library/Fonts/Helvetica.ttc", size=30, index=1, margin=8, gap=4) -> Image.Image:
    font = ImageFont.truetype(font_path, size, index=index)   # index 1 = Helvetica Bold
    lines = []
    for paragraph in text.replace("\r", "").split("\n"):      # newlines first, then wrap each paragraph
        cur = ""
        for word in paragraph.split():
            trial = (cur + " " + word).strip()
            if font.getlength(trial) <= WIDTH - 2 * margin: cur = trial; continue
            if cur: lines.append(cur)
            piece = ""
            for ch in word:                                     # a word wider than the paper breaks by character
                if font.getlength(piece + ch) <= WIDTH - 2 * margin: piece += ch
                else: lines.append(piece); piece = ch
            cur = piece
        lines.append(cur)
    while len(lines) > 1 and lines[-1] == "": lines.pop()
    lh = size + gap
    img = Image.new("1", (WIDTH, margin + lh * len(lines) + margin), 1)
    d = ImageDraw.Draw(img)
    for i, line in enumerate(lines): d.text((margin, margin + i * lh), line, font=font, fill=0)
    return img

def raster(img: Image.Image) -> bytes:   # 1 = black, LSB-first within each byte
    px = img.load(); out = bytearray()
    for y in range(img.height):
        for bx in range(WIDTH // 8):
            v = 0
            for bit in range(8):
                if px[bx * 8 + bit, y] == 0: v |= 1 << bit
            out.append(v)
    return bytes(out)

async def print_raster(data: bytes, height: int, name: str, darkness: int):
    paused = asyncio.Event(); paused.set()
    acks = {"a9": asyncio.Event(), "aa": asyncio.Event()}; status = {}
    def on_notify(sender, raw):
        raw = bytes(raw); print(f"  notify {raw.hex()}")
        if raw in PAUSE: paused.clear(); return
        if raw in RESUME: paused.set(); return
        if raw[:2] != b"\x22\x21" or len(raw) < 6: return
        op, body = raw[2], raw[6:6 + (raw[4] | raw[5] << 8)]
        if op == 0xA9: status["a9"] = body[0] if body else None; acks["a9"].set()
        elif op == 0xAA: acks["aa"].set()
        elif op == 0xB1: status["firmware"] = body.decode("ascii", "replace").strip("\x00")
        elif op == 0xA1 and len(body) >= 8: status["state"], status["battery"], status["temp"] = body[0], body[3], body[4]
    dev = await BleakScanner.find_device_by_name(name, timeout=15.0)
    if not dev: sys.exit(f"{name} not found — press the printer's button and try again")
    async with BleakClient(dev, timeout=20.0) as c:
        print(f"connected {name}, mtu {c.mtu_size}")
        await c.start_notify(AE02, on_notify)
        try: await c.start_notify(AE04, on_notify)
        except Exception: pass
        await asyncio.sleep(0.2)
        await c.write_gatt_char(AE01, CONNECT_INIT, response=False); await asyncio.sleep(0.5)
        await c.write_gatt_char(AE01, GET_SERIAL, response=False); await asyncio.sleep(0.3)
        await c.write_gatt_char(AE01, packet(0xA2, bytes([DENSITY[darkness - 1]])), response=False); await asyncio.sleep(0.1)
        await c.write_gatt_char(AE01, start_print(height), response=False)
        await asyncio.wait_for(acks["a9"].wait(), 5.0)
        if status.get("a9") != 0: sys.exit(f"printer not ready (A9 status {status.get('a9')}) — paper? lid?")
        chunk = min(180, c.mtu_size - 5)
        for i in range(0, len(data), chunk):
            await asyncio.wait_for(paused.wait(), 30)
            await c.write_gatt_char(AE03, data[i:i + chunk], response=False)
            await asyncio.sleep(0.03)
        await c.write_gatt_char(AE01, FINALIZE, response=False)
        try: await asyncio.wait_for(acks["aa"].wait(), 60.0); print("printed (AA)")
        except asyncio.TimeoutError: print("no AA within 60 s")
        await asyncio.sleep(2.0)   # grace: disconnecting early truncates the feed
        print("status:", status)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("text"); ap.add_argument("--name", default="JK01")
    ap.add_argument("--darkness", type=int, default=5); ap.add_argument("--png")
    ap.add_argument("--fixtures", metavar="DIR", help="write hello.txt / hello.pbm / hello.transcript.hex for the Kit tests and exit")
    a = ap.parse_args()
    img = render(a.text)
    if a.png: img.save(a.png); print("preview", a.png)
    if a.fixtures:
        import pathlib
        d = pathlib.Path(a.fixtures); d.mkdir(parents=True, exist_ok=True)
        (d / "hello.txt").write_text(a.text)
        px = img.load()
        (d / "hello.pbm").write_text("P1\n%d %d\n" % (img.width, img.height) + "".join("".join("1" if px[x, y] == 0 else "0" for x in range(img.width)) + "\n" for y in range(img.height)))
        data = raster(img)
        (d / "hello.transcript.hex").write_text("\n".join([packet(0xA2, bytes([DENSITY[a.darkness - 1]])).hex(), start_print(img.height).hex(), data.hex(), FINALIZE.hex()]) + "\n")
        print("fixtures in", d, "rows", img.height, "ink", sum(1 for y in range(img.height) for x in range(img.width) if px[x, y] == 0) / (img.width * img.height))
        sys.exit(0)
    asyncio.run(print_raster(raster(img), img.height, a.name, max(1, min(5, a.darkness))))
