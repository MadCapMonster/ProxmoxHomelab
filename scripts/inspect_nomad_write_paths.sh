#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${1:-nomad_admin}"

section() {
  printf '\n===== %s =====\n' "$1"
}

run() {
  printf '\n$ %s\n' "$*"
  bash -lc "$*" || true
}

section "Container basic info"
run "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | sed -n '1,20p'"
run "docker inspect ${CONTAINER} --format 'Name={{.Name}} Image={{.Config.Image}}'"

section "Container mount mappings"
run "docker inspect ${CONTAINER} --format '{{range .Mounts}}{{println .Type \"|\" .Source \"->\" .Destination \"| rw=\" .RW}}{{end}}'"

section "Likely write locations inside container"
run "docker exec ${CONTAINER} sh -lc 'for p in /app/storage /data /data/media /tmp /var/tmp; do [ -e \"\$p\" ] && echo \"FOUND \$p\"; done'"

section "Disk usage for likely paths inside container"
run "docker exec ${CONTAINER} sh -lc 'for p in /app/storage /data /data/media; do [ -e \"\$p\" ] && { echo; echo \"## \$p\"; du -sh \"\$p\" 2>/dev/null; }; done'"

section "Recent files written inside container (last 60 mins)"
run "docker exec ${CONTAINER} sh -lc 'find /app/storage /data /tmp /var/tmp -xdev -type f -mmin -60 2>/dev/null | sed -n \"1,200p\"'"

section "Recent files written on host bind mounts (last 60 mins)"
run "find /opt/project-nomad/storage /data -xdev -type f -mmin -60 2>/dev/null | sed -n '1,300p'"

section "Top-level contents of host storage paths"
run "ls -lah /opt/project-nomad/storage | sed -n '1,120p'"
run "ls -lah /data | sed -n '1,120p'"
run "ls -lah /data/media 2>/dev/null | sed -n '1,120p'"

section "Writable test targets from container"
run "docker exec ${CONTAINER} sh -lc 'for p in /app/storage /data /data/media; do if [ -d \"\$p\" ]; then f=\"\$p/.write_test_\$(date +%s)\"; if echo test > \"\$f\" 2>/dev/null; then echo \"WRITE OK: \$p\"; rm -f \"\$f\"; else echo \"WRITE FAIL: \$p\"; fi; fi; done'"

section "Application environment hints"
run "docker inspect ${CONTAINER} --format '{{range .Config.Env}}{{println .}}{{end}}' | egrep '^(URL=|NODE_ENV=|DB_|REDIS_|APP_KEY=|PORT=|HOST=)'"

section "Logs that may reveal paths"
run "docker logs --tail=200 ${CONTAINER} 2>&1 | egrep -i 'storage|write|path|media|import|upload|saved|created' | sed -n '1,200p'"

section "Summary"
cat <<'EOF'
Look at:
- "Container mount mappings" to see host->container path bindings.
- "Recent files written on host bind mounts" to see where new content is landing.
- "Writable test targets" to confirm which paths the app can write to.

Most likely:
- app-managed metadata/logs/uploads go to /app/storage on the host as /opt/project-nomad/storage
- your content library path, if configured, should go to /data or /data/media
EOF
