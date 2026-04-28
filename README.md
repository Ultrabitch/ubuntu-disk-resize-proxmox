# Ubuntu Disk Resize & Rescue (Proxmox / KVM / any cloud VM)

> Resize a full Ubuntu disk **even when it's already at 100%**, then prevent it from ever locking you out again.

Your VM disk grew (Proxmox, Hetzner, OVH, AWS, GCP — same story), `df -h` now reads `100%`, SSH still works but every write fails, and your usual incantation —

```bash
sudo growpart /dev/sda 1 && sudo resize2fs /dev/sda1
```

— refuses with `No space left on device`. This repo gives you:

1. A **one-line rescue script** to recover from a fully saturated `/`.
2. A **manual procedure** for ordinary growth operations.
3. **Prevention tips** so the next time the disk fills, you stay in control.

---

## ⚡ Quick start

### Just fix it (auto mode)

```bash
curl -fsSL https://raw.githubusercontent.com/tradersquareoff/ubuntu-disk-resize-proxmox/main/disk-rescue.sh | sudo bash
```

The script auto-detects state. If `/` is ≥95% it frees emergency space first, then runs `growpart` + `resize2fs`, then offers to install a ballast file for next time.

### Pick a specific mode

```bash
# Read-only diagnostic — what's eating my disk?
curl -fsSL https://raw.githubusercontent.com/tradersquareoff/ubuntu-disk-resize-proxmox/main/disk-rescue.sh | sudo bash -s -- --diagnose

# Free emergency space (drop ballast, vacuum journald, clean apt cache, prune /tmp)
curl -fsSL https://raw.githubusercontent.com/tradersquareoff/ubuntu-disk-resize-proxmox/main/disk-rescue.sh | sudo bash -s -- --rescue

# Just resize the partition + filesystem
curl -fsSL https://raw.githubusercontent.com/tradersquareoff/ubuntu-disk-resize-proxmox/main/disk-rescue.sh | sudo bash -s -- --resize

# Pre-install a 2 GB emergency ballast file for the future
curl -fsSL https://raw.githubusercontent.com/tradersquareoff/ubuntu-disk-resize-proxmox/main/disk-rescue.sh | sudo bash -s -- --ballast 2G
```

| Flag | What it does |
|---|---|
| `--auto` *(default)* | Detect → rescue if full → resize → optionally install ballast |
| `--diagnose`, `-d` | Print disk + top space consumers, read-only |
| `--rescue`, `-r` | Free emergency space (ballast, journald, apt, snap, /tmp) |
| `--resize`, `-z` | `growpart` + `resize2fs` (uses `/dev/shm` as `TMPDIR`) |
| `--ballast [SIZE]` | Allocate immutable filler (default 2G) at `/root/.disk-rescue-ballast` |
| `--remove-ballast` | Remove the ballast (lifts immutable flag first) |
| `--yes`, `-y` | Skip confirmations (for non-interactive runs) |

Override autodetection with env vars: `DISK=/dev/vda PART=/dev/vda1 PARTNUM=1 MOUNT=/`.

---

## 🆘 The "disk is 100% full and I can't resize" trap

This is the case nobody warns you about. You hit it exactly once, you lose an hour of your life, and you swear it'll never happen again. Here's *why* it happens and how this repo handles it.

**Why `growpart` fails on a full disk**
`growpart` reads/writes the partition table via temporary files. By default `TMPDIR=/tmp`, and `/tmp` lives on the very partition you're trying to grow. No space → no temp file → no resize.

**Why `resize2fs` can also fail**
ext4 needs a tiny amount of free metadata space to extend; on a truly saturated filesystem (reserved blocks exhausted too) it bails out.

**The two escape hatches**

| Solution | Use when |
|---|---|
| **Drop a pre-allocated ballast file** to instantly free 2 GB | You planned ahead with `--ballast` |
| **Redirect `growpart`'s tempdir to tmpfs**: `TMPDIR=/dev/shm growpart /dev/sda 1` | You didn't plan ahead, but `/dev/shm` (RAM-backed) has free space |

This script does **both**: it removes the ballast if present, then runs `growpart` with `TMPDIR=/dev/shm`. Belt and braces.

---

## 🛠 Manual procedure (for those who prefer the long form)

### 1. Grow the underlying virtual disk

**Proxmox VE:**
1. Shut down the VM (or hot-grow if your storage backend supports it).
2. **Hardware** → select the disk → **Resize** → enter `+10G` (or your target).
3. Power the VM back on.

**Other hypervisors / clouds:** resize via your control panel or API (e.g. `gcloud compute disks resize`, `aws ec2 modify-volume`).

### 2. Verify the kernel sees the new size

```bash
lsblk
# /dev/sda should show the new size; /dev/sda1 still shows the old size.
```

If `lsblk` still shows the old disk size, force a rescan:

```bash
echo 1 | sudo tee /sys/class/block/sda/device/rescan
```

### 3. Extend the partition

```bash
sudo apt update && sudo apt install -y cloud-guest-utils   # provides growpart
sudo growpart /dev/sda 1
```

> **Disk full?** Prefix with `TMPDIR=/dev/shm`:
> ```bash
> sudo TMPDIR=/dev/shm growpart /dev/sda 1
> ```

### 4. Resize the filesystem

```bash
# ext2/3/4
sudo resize2fs /dev/sda1

# xfs (resize is online, by mountpoint not device)
sudo xfs_growfs /

# btrfs
sudo btrfs filesystem resize max /
```

**LVM users:**
```bash
sudo pvresize /dev/sda3
sudo lvextend -l +100%FREE /dev/mapper/<vg>-<lv>
sudo resize2fs /dev/mapper/<vg>-<lv>     # or xfs_growfs / on xfs
```

### 5. Verify

```bash
df -h /
lsblk
```

---

## 🛡 Prevention — never get locked out again

### 1. Install the emergency ballast (the single most useful trick)

A 2 GB pre-allocated file you can delete in one command to free space instantly:

```bash
sudo fallocate -l 2G /root/.disk-rescue-ballast
sudo chattr +i /root/.disk-rescue-ballast      # immutable: prevents accidental rm
```

To free the space in an emergency:

```bash
sudo chattr -i /root/.disk-rescue-ballast
sudo rm /root/.disk-rescue-ballast
```

Or just `sudo bash disk-rescue.sh --rescue` and the script does it for you.

### 2. Alert before you saturate

A 15-minute cron that emails you when `/` crosses 80%:

```cron
*/15 * * * * [ "$(df / | awk 'NR==2{print int($5)}')" -gt 80 ] && \
  echo "Disk $(df -h / | awk 'NR==2{print $5}') on $(hostname)" | \
  mail -s "Disk alert: $(hostname)" you@example.com
```

### 3. Find and stop the source of growth

The most common silent disk eaters on Ubuntu VMs:

| Suspect | Quick check |
|---|---|
| Systemd journal | `journalctl --disk-usage` — vacuum with `journalctl --vacuum-size=500M` |
| Docker | `docker system df` — prune with `docker system prune -af --volumes` |
| Snap old revisions | `snap list --all \| grep disabled` |
| Old kernels | `dpkg -l 'linux-image-*' \| grep ^ii` |
| Apt cache | `du -sh /var/cache/apt/archives` |
| Per-app data dirs | `du -h -d 1 -x /home /opt /var/lib \| sort -hr \| head` |
| Git worktrees / build artifacts | check `~/.cache`, `~/.npm`, `node_modules`, agent worktree dirs |

Run `disk-rescue.sh --diagnose` to get this report in one command.

---

## 🧯 Troubleshooting

| Symptom | Fix |
|---|---|
| `growpart: command not found` | `sudo apt install cloud-guest-utils` |
| `growpart: NOCHANGE: partition X is size Y. it cannot be grown` | Hypervisor hasn't pushed the new size to the kernel — re-run `echo 1 \| sudo tee /sys/class/block/sda/device/rescan` |
| `resize2fs: Bad magic number in super-block` | You ran it on the wrong device — confirm with `lsblk -f` |
| `e2fsck` complains | `sudo umount` if possible, then `sudo e2fsck -f /dev/sdaX` before resizing |
| Partition overlap | VM wasn't fully shut down before the host-side resize, or another partition is in the way (e.g. swap on `sda2`) — move/delete it first |
| LVM volume group name unknown | `sudo vgs` and `sudo lvs` |

---

## 🧪 What the script actually does (in plain English)

- **`--diagnose`**: `df`, `lsblk`, `du -d1` on `/`, `/var`, `/home`, `df -i` for inodes. Reports whether a ballast is present.
- **`--rescue`**: removes ballast (if any), `journalctl --vacuum-time=2d`, `apt-get clean && autoremove`, removes disabled snap revisions, deletes `/tmp` and `/var/tmp` entries older than 7 days.
- **`--resize`**: installs `cloud-guest-utils` if needed, runs `growpart` with `TMPDIR=/dev/shm`, then `resize2fs` / `xfs_growfs` / `btrfs filesystem resize max` based on the actual filesystem of `/`.
- **`--ballast`**: `fallocate` then `chattr +i`. Idempotent.

The script is `set -euo pipefail`, runs as root, supports nvme device naming (`/dev/nvme0n1p1`), and exits cleanly if `growpart` reports `NOCHANGE`.

---

## 🤝 Contributing

Bugs, edge cases (LVM-on-LUKS? bcachefs? Talos?), and PRs welcome. Tested on Ubuntu 20.04 / 22.04 / 24.04 against Proxmox VE 7/8 and KVM.

## 📜 License

MIT.

## 🔗 References

- [Proxmox VE — Resize Disks](https://pve.proxmox.com/wiki/Resize_disks)
- [cloud-utils / growpart](https://manpages.ubuntu.com/manpages/jammy/man1/growpart.1.html)
- [Ubuntu Server Guide](https://ubuntu.com/server/docs)
