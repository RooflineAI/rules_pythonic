#!/usr/bin/env python3
"""
Experiment 1: Where are the filesystem boundaries?

Maps out which paths are on which filesystem/device.
This tells us where hardlinks CAN and CANNOT work.
"""
import os
import tempfile

paths_to_check = [
    ("Home dir (~)", os.path.expanduser("~")),
    ("Default uv cache", os.path.expanduser("~/.cache/uv")),
    ("/tmp", "/tmp"),
    ("Working dir (cwd)", os.getcwd()),
    ("/workspace (if exists)", "/workspace"),
]

print("=== Filesystem boundaries ===")
print(f"{'Label':<30s} {'Device':<20s} {'Filesystem':<15s} {'Path'}")
print("-" * 90)

seen_devices = {}
for label, path in paths_to_check:
    if not os.path.exists(path):
        print(f"{label:<30s} {'(not found)':<20s} {'—':<15s} {path}")
        continue
    st = os.stat(path)
    dev = st.st_dev

    # Get filesystem type via /proc/mounts (Linux-specific)
    fs_type = "?"
    try:
        with open("/proc/mounts") as f:
            best_match = ""
            for line in f:
                parts = line.split()
                mount_point = parts[1]
                if path.startswith(mount_point) and len(mount_point) > len(best_match):
                    best_match = mount_point
                    fs_type = parts[2]
    except Exception:
        pass

    dev_str = f"{os.major(dev)}:{os.minor(dev)}"
    if dev not in seen_devices:
        seen_devices[dev] = label
    print(f"{label:<30s} {dev_str:<20s} {fs_type:<15s} {path}")

print()
print("=== Hardlink compatibility ===")
devices = {}
for label, path in paths_to_check:
    if os.path.exists(path):
        devices.setdefault(os.stat(path).st_dev, []).append(label)

for dev, labels in devices.items():
    dev_str = f"{os.major(dev)}:{os.minor(dev)}"
    if len(labels) > 1:
        print(f"  Device {dev_str}: {', '.join(labels)} — hardlinks WILL work between these")
    else:
        print(f"  Device {dev_str}: {labels[0]} — isolated")

print()

# Test actual hardlink between /tmp and cwd
print("=== Cross-path hardlink test ===")
test_pairs = [
    ("cwd -> cwd", os.getcwd(), os.getcwd()),
    ("/tmp -> /tmp", "/tmp", "/tmp"),
    ("cwd -> /tmp", os.getcwd(), "/tmp"),
]
for label, src_dir, dst_dir in test_pairs:
    src = os.path.join(src_dir, "_hl_test_src")
    dst = os.path.join(dst_dir, "_hl_test_dst")
    try:
        with open(src, "w") as f:
            f.write("test")
        os.link(src, dst)
        src_ino = os.stat(src).st_ino
        dst_ino = os.stat(dst).st_ino
        nlink = os.stat(src).st_nlink
        same = src_ino == dst_ino and nlink > 1
        print(f"  {label:<20s} {'OK — same inode, nlink=' + str(nlink) if same else 'FAIL — different inodes'}")
    except OSError as e:
        print(f"  {label:<20s} FAIL — {e}")
    finally:
        for f in [src, dst]:
            try: os.unlink(f)
            except: pass
