"""Capture tagline.html's kinetic reveal as a transparent PNG sequence.

Usage: python3 capture_frames.py <out_dir> [width] [height]

Each frame is saved with a true alpha channel (page background is
transparent; omit_background keeps the browser's own canvas transparent
too). Real capture timestamps are recorded to timestamps.json so
build_concat_list.py can re-time the sequence to a constant output fps
regardless of how long each screenshot took to render.
"""
import time, os, sys, json
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE_URL = "file://" + os.path.join(os.path.dirname(HERE), "tagline.html")

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "./frames"
WIDTH = int(sys.argv[2]) if len(sys.argv) > 2 else 1280
HEIGHT = int(sys.argv[3]) if len(sys.argv) > 3 else 720

os.makedirs(OUT_DIR, exist_ok=True)
for f in os.listdir(OUT_DIR):
    os.remove(os.path.join(OUT_DIR, f))

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
    page = b.new_page(viewport={"width": WIDTH, "height": HEIGHT})
    page.goto(PAGE_URL)
    page.wait_for_function("document.fonts.status === 'loaded'")
    total_ms = page.evaluate("window.ANIM_TOTAL_MS")
    print("ANIM_TOTAL_MS =", total_ms)

    # reload for a clean, freshly-timed run right before capturing
    page.reload()
    page.wait_for_function("document.fonts.status === 'loaded'")

    t0 = time.time()
    total_s = total_ms / 1000.0 + 0.1
    timestamps = []
    i = 0
    while True:
        elapsed = time.time() - t0
        if elapsed > total_s:
            break
        path = os.path.join(OUT_DIR, f"frame_{i:04d}.png")
        page.screenshot(path=path, omit_background=True)
        timestamps.append(elapsed)
        i += 1
    timestamps.append(total_s)  # sentinel end timestamp
    b.close()

with open(os.path.join(OUT_DIR, "timestamps.json"), "w") as f:
    json.dump(timestamps, f)

print(f"Captured {len(timestamps) - 1} frames over {timestamps[-1]:.3f}s -> {OUT_DIR}")
