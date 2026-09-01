#!/bin/bash
#
# Optionally run Docker-in-Docker service.
# Requires sysbox installed on the host.
#
set -u -e

# We use the init script and not systemd, because containerd's systemctl script
# tries to modprobe, fails and shows a nasty warning.
rm -f /var/run/docker.pid || true

say "Starting Docker-in-Docker..."
/etc/init.d/docker start &

# Wait (bounded) until the daemon actually accepts connections before letting
# later entrypoints run. Dockerd resets /var/lib/docker while it initializes,
# so an entrypoint that prepares content there (e.g. a derived image linking
# docker volumes to a RAM dir) would race that reset and get silently
# clobbered - and the runner would then pick up jobs with a broken docker data
# path. A daemon that dies instead of becoming ready falls through to the
# historic "we still continue" contract for hosts without sysbox.
DIND_READY_TIMEOUT_SEC="${DIND_READY_TIMEOUT_SEC:-90}"
for (( _sec = 0; _sec < DIND_READY_TIMEOUT_SEC; _sec++ )); do
  if timeout 5 docker info >/dev/null 2>&1; then
    say "Docker-in-Docker is ready."
    break
  fi
  # The init script forks, so give the daemon a grace period to appear in the
  # process list before treating its absence as an early death.
  if (( _sec >= 10 )) && ! pgrep dockerd >/dev/null; then
    say "Warning: Docker-in-Docker is not running; not waiting for it."
    break
  fi
  sleep 1
done

dind_loop() {
  for _n in {0..9}; do
    sleep 5
    if ! pgrep dockerd >/dev/null; then
      log=/var/log/docker.log
      say "Warning: Docker-in-Docker died; we still continue though."
      say "- Maybe sysbox is not installed on the host system?"
      say "- Or maybe you run this container on a Docker Desktop host?"
      say "Logs from $log:"
      tail -n 15 $log | sed -E "s/^ +//" | grep . || true
      break
    fi
  done
}

dind_loop &
