#!/usr/bin/env bash
#
# disk-rescue.sh — Ubuntu disk rescue & resize helper
# https://github.com/tradersquareoff/ubuntu-disk-resize-proxmox
#
# Usage (one-liners):
#   curl -fsSL https://raw.githubusercontent.com/tradersquareoff/ubuntu-disk-resize-proxmox/main/disk-rescue.sh | sudo bash
#   curl -fsSL .../disk-rescue.sh | sudo bash -s -- --auto
#   curl -fsSL .../disk-rescue.sh | sudo bash -s -- --diagnose
#   curl -fsSL .../disk-rescue.sh | sudo bash -s -- --rescue
#   curl -fsSL .../disk-rescue.sh | sudo bash -s -- --resize
#   curl -fsSL .../disk-rescue.sh | sudo bash -s -- --ballast 2G
#   curl -fsSL .../disk-rescue.sh | sudo bash -s -- --remove-ballast
#
# Modes:
#   --auto           Detect state, free space if full, then run resize. Default if no flag.
#   --diagnose, -d   Print disk + top space users (read-only).
#   --rescue, -r     Free emergency space: drop ballast, journal, apt cache, tmp.
#   --resize, -z     Run growpart + resize2fs (uses /dev/shm for tmp on full disk).
#   --ballast [SIZE] Install /root/.disk-rescue-ballast (default 2G), set immutable.
#   --remove-ballast Remove the ballast (and its immutable flag).
#   --yes, -y        Skip confirmations.
#   --help, -h       Show this help.
#
# Environment overrides: DISK, PART, PARTNUM, MOUNT, BALLAST_PATH

set -euo pipefail

# -------- defaults & detection ------------------------------------------------

MOUNT="${MOUNT:-/}"
BALLAST_PATH="${BALLAST_PATH:-/root/.disk-rescue-ballast}"
DEFAULT_BALLAST_SIZE="2G"
ASSUME_YES="${ASSUME_YES:-0}"

# Colors (only on TTY)
if [[ -t 1 ]]; then
  C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
  C_BLUE='\033[0;34m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

log()  { printf "${C_BLUE}==>${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}✓${C_RESET}  %s\n" "$*"; }
warn() { printf "${C_YELLOW}!${C_RESET}  %s\n" "$*" >&2; }
err()  { printf "${C_RED}✗${C_RESET}  %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "This action requires root. Re-run with sudo."
  fi
}

confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  if [[ ! -t 0 ]]; then
    warn "Non-interactive shell — pass --yes to confirm. Skipping: $1"
    return 1
  fi
  read -r -p "$(printf "${C_YELLOW}?${C_RESET} %s [y/N] " "$1")" reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

detect_partition() {
  # Resolve the device backing $MOUNT (e.g. /dev/sda1)
  local src
  src="$(findmnt -no SOURCE "$MOUNT")" || die "Cannot find mount source for $MOUNT"

  # Resolve symlinks like /dev/root → /dev/sda1
  if [[ -L "$src" ]]; then
    src="$(readlink -f "$src")"
  elif [[ "$src" == "/dev/root" ]]; then
    # Last-ditch: read from /proc/cmdline or use lsblk
    src="$(lsblk -no PKNAME,NAME --raw "$src" 2>/dev/null | head -1 || true)"
    [[ -z "$src" ]] && src="$(findmnt -no SOURCE "$MOUNT")"
  fi

  PART="${PART:-$src}"
  # Strip trailing digits to get parent disk; handle nvme0n1p1 → nvme0n1
  if [[ "$PART" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
    DISK="${DISK:-${BASH_REMATCH[1]}}"
    PARTNUM="${PARTNUM:-${BASH_REMATCH[2]}}"
  elif [[ "$PART" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
    DISK="${DISK:-${BASH_REMATCH[1]}}"
    PARTNUM="${PARTNUM:-${BASH_REMATCH[2]}}"
  else
    die "Could not parse disk/partition from $PART. Set DISK, PART, PARTNUM env vars."
  fi
}

usage_pct() {
  df --output=pcent "$MOUNT" | tail -1 | tr -dc '0-9'
}

avail_bytes() {
  df --output=avail -B1 "$MOUNT" | tail -1 | tr -d ' '
}

human() {
  numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"
}

# -------- commands ------------------------------------------------------------

cmd_diagnose() {
  log "Disk usage on $MOUNT"
  df -h "$MOUNT"
  echo
  log "Block devices"
  lsblk -e7
  echo
  log "Top 15 space users under / (one level)"
  du -h -d 1 -x / 2>/dev/null | sort -hr | head -15
  echo
  log "Top 15 under /var and /home"
  du -h -d 2 -x /var /home 2>/dev/null | sort -hr | head -15
  echo
  log "Inode usage"
  df -i "$MOUNT"
  echo
  if [[ -e "$BALLAST_PATH" ]]; then
    local sz
    sz="$(stat -c%s "$BALLAST_PATH")"
    ok "Ballast present at $BALLAST_PATH ($(human "$sz")) — drop it via --rescue or --remove-ballast"
  else
    warn "No ballast file at $BALLAST_PATH. Install one via --ballast for future emergencies."
  fi
}

cmd_rescue() {
  require_root
  local before after freed
  before="$(avail_bytes)"
  log "Free before: $(human "$before") on $MOUNT"

  # 1. Drop the ballast if it exists — fastest, most predictable win
  if [[ -e "$BALLAST_PATH" ]]; then
    log "Removing ballast $BALLAST_PATH"
    chattr -i "$BALLAST_PATH" 2>/dev/null || true
    rm -f "$BALLAST_PATH"
    ok "Ballast dropped"
  fi

  # 2. Vacuum journald to last 2 days
  if command -v journalctl >/dev/null 2>&1; then
    log "Vacuuming systemd journal (keep 2 days)"
    journalctl --vacuum-time=2d 2>&1 | tail -3 || true
  fi

  # 3. Clean apt cache
  if command -v apt-get >/dev/null 2>&1; then
    log "Cleaning apt cache"
    apt-get clean -y >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
  fi

  # 4. Clean snap old revisions
  if command -v snap >/dev/null 2>&1; then
    log "Removing disabled snap revisions"
    snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | \
      while read -r name rev; do snap remove "$name" --revision="$rev" 2>/dev/null || true; done
  fi

  # 5. Trim /tmp and /var/tmp of plain files older than 7 days
  #    (-type f only — never touch system socket dirs like .X11-unix, .ICE-unix)
  log "Trimming /tmp and /var/tmp (regular files >7 days old)"
  local removed
  removed="$(find /tmp /var/tmp -mindepth 1 -type f -mtime +7 -print -delete 2>/dev/null | wc -l)"
  echo "  removed $removed files"

  after="$(avail_bytes)"
  freed=$(( after - before ))
  ok "Free after:  $(human "$after") (recovered $(human "$freed"))"
}

cmd_resize() {
  require_root
  detect_partition

  command -v growpart >/dev/null 2>&1 || {
    log "Installing cloud-guest-utils for growpart"
    apt-get update -qq && apt-get install -y cloud-guest-utils >/dev/null
  }

  log "Resizing partition $PART (disk $DISK, num $PARTNUM)"

  # Use /dev/shm as TMPDIR — works even when / is full
  if ! TMPDIR=/dev/shm growpart "$DISK" "$PARTNUM"; then
    rc=$?
    if [[ $rc -eq 1 ]]; then
      warn "growpart returned 1 — likely 'NOCHANGE' (partition already at max). Continuing."
    else
      die "growpart failed with exit code $rc"
    fi
  fi

  log "Resizing filesystem on $PART"
  local fstype
  fstype="$(findmnt -no FSTYPE "$MOUNT")"
  case "$fstype" in
    ext2|ext3|ext4) resize2fs "$PART" ;;
    xfs)            xfs_growfs "$MOUNT" ;;
    btrfs)          btrfs filesystem resize max "$MOUNT" ;;
    *) die "Unsupported filesystem: $fstype" ;;
  esac

  ok "Resize complete"
  df -h "$MOUNT"
}

cmd_ballast() {
  require_root
  local size="${1:-$DEFAULT_BALLAST_SIZE}"
  if [[ -e "$BALLAST_PATH" ]]; then
    ok "Ballast already exists at $BALLAST_PATH ($(human "$(stat -c%s "$BALLAST_PATH")"))"
    return 0
  fi
  local avail
  avail="$(avail_bytes)"
  log "Allocating $size ballast at $BALLAST_PATH (free: $(human "$avail"))"
  fallocate -l "$size" "$BALLAST_PATH" || die "fallocate failed — not enough space?"
  chmod 600 "$BALLAST_PATH"
  chattr +i "$BALLAST_PATH" 2>/dev/null || warn "chattr +i failed (filesystem may not support it)"
  ok "Ballast installed. In a future emergency, drop it via: $0 --rescue"
}

cmd_remove_ballast() {
  require_root
  if [[ ! -e "$BALLAST_PATH" ]]; then
    ok "No ballast at $BALLAST_PATH"
    return 0
  fi
  chattr -i "$BALLAST_PATH" 2>/dev/null || true
  rm -f "$BALLAST_PATH"
  ok "Ballast removed"
}

cmd_auto() {
  require_root
  local pct
  pct="$(usage_pct)"
  log "Mount $MOUNT is at ${pct}% used"

  if (( pct >= 95 )); then
    warn "Critical usage — running rescue first"
    cmd_rescue
    echo
  fi

  log "Running resize"
  cmd_resize
  echo

  if [[ ! -e "$BALLAST_PATH" ]]; then
    if confirm "Install a ${DEFAULT_BALLAST_SIZE} ballast at $BALLAST_PATH for next time?"; then
      cmd_ballast "$DEFAULT_BALLAST_SIZE"
    fi
  fi
}

usage() {
  awk '/^# Environment overrides:/{print; exit} /^#/{print}' "$0" | \
    sed -e '1d' -e 's/^# \{0,1\}//'
}

# -------- arg parsing ---------------------------------------------------------

ACTION="auto"
BALLAST_SIZE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)         usage; exit 0 ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -d|--diagnose)     ACTION="diagnose"; shift ;;
    -r|--rescue)       ACTION="rescue"; shift ;;
    -z|--resize)       ACTION="resize"; shift ;;
    --auto)            ACTION="auto"; shift ;;
    --ballast)         ACTION="ballast"; shift
                       if [[ $# -gt 0 && "$1" != -* ]]; then BALLAST_SIZE_ARG="$1"; shift; fi ;;
    --remove-ballast)  ACTION="remove-ballast"; shift ;;
    *)                 die "Unknown argument: $1 (use --help)" ;;
  esac
done

case "$ACTION" in
  diagnose)        cmd_diagnose ;;
  rescue)          cmd_rescue ;;
  resize)          cmd_resize ;;
  ballast)         cmd_ballast "${BALLAST_SIZE_ARG:-$DEFAULT_BALLAST_SIZE}" ;;
  remove-ballast)  cmd_remove_ballast ;;
  auto)            cmd_auto ;;
esac
