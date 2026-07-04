#!/bin/sh
# Mounts the WD NAS's archive-box NFS export directly inside this
# podman-machine VM (Fedora CoreOS), rather than relying on virtiofs to
# pass through a host-side NFS mount — virtiofs does not reliably cross a
# submount boundary (confirmed empirically: the host-side mount at
# /private/var/nfs/archivebox-archive showed up in this VM's mount table
# but every file operation through it failed with ENOENT). Mounting natively
# inside the VM, where the container runtime itself runs, sidesteps that
# entirely.
#
# hard,intr: a dropped NAS connection should hang and be interruptible, not
# silently truncate a write — this is archive data, not a cache.

NAS_HOST="10.0.1.12"
NAS_EXPORT="/mnt/HD/HD_a2/archive-box"
MOUNT_POINT="/var/mnt/archivebox-archive"
LOG="/var/log/archivebox-nfs-mount.log"

echo "=== $(date '+%Y-%m-%d %H:%M:%S') boot: mounting NAS archive share ===" >> "$LOG"

i=0
while [ "$i" -lt 60 ]; do
  ping -c1 -W1 "$NAS_HOST" >/dev/null 2>&1 && break
  i=$((i + 1)); sleep 2
done

if mount | grep -q " on $MOUNT_POINT "; then
  echo "$(date '+%H:%M:%S') already mounted, skipping" >> "$LOG"
else
  mkdir -p "$MOUNT_POINT"
  mount -t nfs -o vers=3,hard,intr,timeo=50,retrans=3 \
    "$NAS_HOST:$NAS_EXPORT" "$MOUNT_POINT" >> "$LOG" 2>&1
  echo "$(date '+%H:%M:%S') mount rc=$?" >> "$LOG"
fi

# The NAS's NFS server applies root_squash: writes from this VM's root user
# land owned by a mapped non-root UID/GID (observed: 501:1000), but the raw
# export root itself is pre-existing, owned by real root — ArchiveBox's own
# init tries to chmod whatever it's given as its archive dir, which fails
# with EPERM against something it doesn't own. A subdirectory *we* create
# here is owned by that same mapped UID, so ArchiveBox (also squashed to
# that UID) owns it and chmod succeeds. Bind-mount this subdirectory, not
# the NFS export root, into the container.
mkdir -p "$MOUNT_POINT/data"

echo "=== $(date '+%H:%M:%S') done ===" >> "$LOG"
