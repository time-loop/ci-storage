#!/bin/bash
#
# In the very end, runs the self-hosted runner and waits for its termination. In
# case a SIGINT or SIGHUP are received, they will be processed by the
# terminate_on_signal() function defined in the config script above.
#
set -u -e

while :; do
  say 'Waiting for the initial "ci-storage load" to finish...'
  pgrep -xa ci-storage || break
  for _i in {1..6}; do
    sleep 0.5
    pgrep -xa ci-storage >/dev/null || break
  done
done

# The runner must not accept jobs while the daemon is still initializing:
# dockerd resets /var/lib/docker as it starts, so a job racing it can observe
# a half-initialized docker data path (e.g. a dangling volumes symlink in
# derived images) and fail in seconds. A daemon which is absent - the
# tolerated no-sysbox case - or which stays wedged past the bound is let
# through: an idle-but-registered runner is the scaler's problem to recycle,
# and a runner with no dockerd at all fails only the jobs that need docker.
if pgrep dockerd >/dev/null; then
  RUNNER_DIND_READY_TIMEOUT_SEC="${RUNNER_DIND_READY_TIMEOUT_SEC:-90}"
  for (( _sec = 0; _sec < RUNNER_DIND_READY_TIMEOUT_SEC; _sec++ )); do
    if timeout 5 docker info >/dev/null 2>&1; then
      break
    fi
    if ! pgrep dockerd >/dev/null; then
      say "Warning: Docker-in-Docker died while waiting for it; continuing."
      break
    fi
    if (( _sec == 0 )); then
      say "Waiting for Docker-in-Docker to become ready before taking jobs..."
    fi
    sleep 1
  done
fi

say "Starting the self-hosted runner..."

# Use "& wait $!" to let terminate_on_signal() properly handle signals for
# graceful termination (we can't use "exec" here).
cd ~/actions-runner && ./run.sh & wait $!
