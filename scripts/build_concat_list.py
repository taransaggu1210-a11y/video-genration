import json, os, sys

frames_dir = sys.argv[1]
ts = json.load(open(os.path.join(frames_dir, "timestamps.json")))
n = len(ts) - 1  # number of actual frame files

lines = []
for i in range(n):
    dur = ts[i + 1] - ts[i]
    lines.append(f"file 'frame_{i:04d}.png'")
    lines.append(f"duration {dur:.4f}")
# concat demuxer quirk: repeat the last file once more without a duration
lines.append(f"file 'frame_{n-1:04d}.png'")

with open(os.path.join(frames_dir, "list.txt"), "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"wrote list.txt with {n} frames")
