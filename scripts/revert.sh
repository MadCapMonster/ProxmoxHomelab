BACKUP_DIR="/root/lxc-net-backups-2026-04-11-141513"

for file in "$BACKUP_DIR"/*.conf.bak; do
  ctid=$(basename "$file" | cut -d'.' -f1)

  echo "Restoring CT $ctid..."

  # Stop container if running
  if pct status "$ctid" | grep -q running; then
    pct shutdown "$ctid" --timeout 60 || pct stop "$ctid"
  fi

  # Restore config
  cp "$file" "/etc/pve/lxc/${ctid}.conf"

  # Start container
  pct start "$ctid"

  echo "CT $ctid restored"
  echo
done
