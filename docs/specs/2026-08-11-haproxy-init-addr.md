# haproxy `init-addr` — let the runner start when the storage host does not resolve

CLK-1515194, Payload A only.

`docker/ci-runner/root/entrypoint.09-forward.sh` generates `/etc/haproxy/haproxy.cfg`
before starting haproxy. Every TCP backend it emits comes from one template line
(line 42 today):

```
  server server$i $host:$port resolvers res resolve-prefer ipv4 check inter 10s fall 6 rise 6
```

Because that line names `$host` as an FQDN, haproxy must turn it into an address at
startup. haproxy's `init-addr` default is `last,libc`: try the address recorded in a
server-state file, then the libc resolver. When every method in the list fails, haproxy
throws a fatal error and **refuses to start** — which is where this spec's original
premise stood. The entrypoint's `/etc/init.d/haproxy start` would fail under `set -e`,
the runner would never come up, and a container that booted while its storage host
happened to be unresolvable would be permanently dead rather than temporarily degraded,
staying dead after the name resolved again because nothing restarts it.

**That premise is false for this config, and verification proved it before the change
shipped.** Every server line the script emits already carries `resolvers res`, and that
clause alone downgrades a failed startup lookup from a fatal `[ALERT]`/exit-1 to a
non-fatal `[WARNING] ... could not resolve address ..., disabling server`. haproxy
already bound its listeners and lived; the runner was never left dead by an unresolvable
storage host on this shape. Measured on `haproxy:2.4` (2.4.36) against unresolvable
`.invalid` hosts, the generated config is accepted identically with and without
`init-addr last,libc,none` — both sides `Configuration file is valid`, exit 0 — and a
foreground start (`haproxy -f <cfg> -db`) stays alive and bound on both sides. The
keyword only makes a difference once `resolvers res` is absent from the server line, a
shape no code path here produces.

The one-line change ships anyway, as hygiene rather than as a fix. Adding `none` to the
end of the chain is haproxy's documented escape hatch — the server starts with no
address, in a down state, and the `resolvers res` section brings it up once the name
resolves — and writing it explicitly states the intended startup behavior where a reader
looks for it, instead of leaving it an emergent property of the resolvers section. It is
defense in depth: inert today, effective only if a future path ever emits a server line
without `resolvers res`. Nothing in this spec may be read as claiming a startup-behavior
improvement or a CI failure-rate improvement.

This spec covers that one-line change and nothing else. Payload B (health-check
retuning) and Payload C (the proof runbook) are explicitly out of scope; see the
principle blocks below.

## decision: Add init-addr last,libc,none to the generated haproxy server line
description: append the documented none fallback as defense in depth — measurement shows the shipping config already survives an unresolvable $FORWARD_HOST via the pre-existing resolvers res clause, so the keyword is inert today and bites only if a future path emits a server line without resolvers
relies_on: health-check-tuning-is-held-with-payload-b
tags: ci-runner, haproxy, dns, startup, defense-in-depth

Edit the single `tcp_line=` assignment in
`docker/ci-runner/root/entrypoint.09-forward.sh` (line 42) to read:

```bash
tcp_line="  server server$i $host:$port resolvers res resolve-prefer ipv4 init-addr last,libc,none check inter 10s fall 6 rise 6"
```

Three properties of this placement are deliberate:

- **Between `resolve-prefer ipv4` and `check`.** haproxy's `server` keywords are
  order-independent, so placement is a readability choice. Putting `init-addr` next
  to the other name-resolution keywords keeps the resolution clause together and —
  more usefully — leaves `check inter 10s fall 6 rise 6` intact as one contiguous
  substring, so the Payload B hold is verifiable by eye in the diff.
- **One line covers both roles.** Primary and backup servers are emitted from this
  same `tcp_line`; the loop only appends the literal ` backup` for `i > 0`. So the
  backup line becomes `... init-addr last,libc,none check inter 10s fall 6 rise 6 backup`,
  which is valid, and no second edit is needed to cover backups.
- **The literal three-method list, not just `none`.** `libc` restates today's
  effective behavior and `last` restates the other half of haproxy's default, so
  writing the full chain means the only *potential* behavioral delta is the terminal
  `none` fallback — and on the shipping shape even that delta is unobservable, per the
  correction above. `last` is separately inert in this config: there is no
  `server-state-file` or `load-server-state-from-file`, so there is never a recorded
  address to reuse. Both cost nothing and become live if state files are adopted or if
  a server line ever loses `resolvers res`.

Do not make the keyword conditional, env-gated, or configurable. It ships
unconditionally.

## entity: Generated haproxy TCP server line
description: contract for the server lines entrypoint.09-forward.sh writes into /etc/haproxy/haproxy.cfg
relies_on: add-init-addr-last-libc-none-to-the-generated-haproxy-server-line
tags: ci-runner, haproxy, generated-config

After this change, for a `FORWARD_PORTS` entry of `<port>` or `<port>/tcp` (and for
`<port>/tcp-backup`, which only reverses the host order), the generated stanza is:

```
listen tcp_<port>
  bind 127.0.0.1:<port>
  server server0 <host0>:<port> resolvers res resolve-prefer ipv4 init-addr last,libc,none check inter 10s fall 6 rise 6
  server server1 <host1>:<port> resolvers res resolve-prefer ipv4 init-addr last,libc,none check inter 10s fall 6 rise 6 backup
  mode tcp
```

Invariants:

- Every emitted `server ` line contains `init-addr last,libc,none` — there is no
  path that emits a server line without it.
- Every emitted `server ` line still ends its health-check clause with the exact
  bytes `check inter 10s fall 6 rise 6` (followed by ` backup` on non-primary
  lines).
- The `resolvers res` / `parse-resolv-conf` / `hold valid 10s` block, the `listen`
  and `bind` lines, `mode`, and the whole UDP/rinetd path are untouched.

Every emitted `server ` line also carries `resolvers res`. That is not incidental here:
it is the clause the startup behavior below actually depends on.

Startup behavior, corrected against measurement. This block originally recorded, as an
accepted consequence *of this change*, that the backend "now starts **down** instead of
the process aborting." The causal attribution is wrong — the down-instead-of-abort
startup comes from the pre-existing `resolvers res` clause, present on the server line
before this diff, not from `init-addr last,libc,none`, which is inert on every line this
script emits.

What still holds, as a property of the pre-existing config rather than a consequence of
this diff: when the name does not resolve at startup the backend starts **down**, so
traffic arriving at `127.0.0.1:<port>` before the name resolves gets a connection the
backend cannot serve, where a hard abort would instead have left the port unlistened.
Once the name resolves, `check inter 10s fall 6 rise 6` needs six passing checks at 10s
intervals — roughly a minute — before the backend carries traffic. That recovery window
is the subject of the held Payload B retune and is knowingly left as-is here.

## principle: Health-check tuning is held with Payload B
description: check inter 10s fall 6 rise 6 stays byte-identical; the 2c retune is deferred pending the Payload C verdict
tags: scope, ci-runner, haproxy

The values `check inter 10s fall 6 rise 6` are not to be adjusted, reordered, or
reformatted by this change, even though the entity block above notes that they set
the ~60s recovery window. Payload B/2c retuning is explicitly deferred pending the
Payload C verdict, and Payload B's other half (2b) lives in `time-loop/sd`, not this
repo. Payload C — the proof runbook covering pup auth and Datadog log pulls — is
human ops work outside this pipeline entirely.

Two neighbouring temptations are also out of scope and must not be folded in: the
compose-recreate cron hazard (deliberately excluded by the ticket) and the sd-side
amplifier fix, which is tracked separately as CLK-1515297 and carries the CI
outcome on its own.

Concretely: the diff for this change is one modified line in one file, plus this
spec. Anything else in the diff is a scope breach.

## principle: Claim only defense in depth — never a repaired restart path, never a CI failure-rate improvement
description: measurement took the restart-path claim away; commit and PR text may claim only the inert defense-in-depth scope, and must disclaim CI failure-rate impact explicitly
tags: delivery, honesty, pr, defense-in-depth

The claim available to us is narrower than this principle first stated. Its original
premise — "this change repairs the restart path: haproxy now starts and binds when
`$FORWARD_HOST` is unresolvable at boot" — was falsified by verification step 3: the
generated config already started and bound in that case, via the pre-existing
`resolvers res` clause. Adding `init-addr last,libc,none` is defense in depth on the
shipping shape, inert today, effective only if a future path emits a server line without
`resolvers res`. That, and nothing larger, is what commit and PR text may claim.

Two disclaimers are therefore mandatory, not optional. The text MUST NOT claim or imply
an improvement in CI failure rate — that attribution is unearned here, and the fix that
actually carries the CI outcome is the sd-side amplifier (CLK-1515297). And it MUST NOT
assert a repaired restart path either, now that measurement has taken that claim away.
A PR body that omits the CI-failure-rate disclaimer is incomplete work; one that markets
a failure-rate win, or a startup-behavior fix, is wrong. The falsified premise is itself
a reportable finding and goes back on CLK-1515194 alongside the PR.

Commit and PR title follow the repo convention:
`fix(eng-prod): <lowercase description> [CLK-1515194]`.

## Verification

Steps 1–4 are the gate and all four must actually be run. Step 5 is best-effort for
a stated reason. Note the shape of the evidence: step 2 proves the keyword is
*emitted*, step 3 establishes what the keyword measurably does on the shape this script
emits and what it does not — neither substitutes for the other, and a grep alone is not
proof of behavior.

1. **Diff shape.** `git diff` touches exactly one line of
   `docker/ci-runner/root/entrypoint.09-forward.sh`, and
   `grep -c 'check inter 10s fall 6 rise 6'` over the file is unchanged at 1.
2. **Generation exercise.** The edit is in-place and changes no line count, so lines
   20–52 remain exactly the `for spec in $FORWARD_PORTS` loop. Extract and run that
   range standalone — this is verified to work with zero stubs:

   ```bash
   sed -n '20,52p' docker/ci-runner/root/entrypoint.09-forward.sh > /tmp/gen.sh
   FORWARD_HOST="a.invalid b.invalid" FORWARD_PORTS="22/tcp 5000/tcp-backup" \
     bash -c 'set -u -e; source /tmp/gen.sh; printf "%s\n" "${tcp_lines[@]}"'
   ```

   Assert every emitted line matching `^ *server ` contains `init-addr last,libc,none`,
   the ` backup` line included. Use the extraction, **not** `source`-ing the whole
   script: on macOS a naive source silently sails past the undefined `say` because
   `/usr/bin/say` exists, then dies writing `/etc/haproxy/haproxy.cfg.new`, producing
   a confusing failure unrelated to the code under test.

   This is a scratch harness, not a committed test: `tests/` here is scaffolding for
   the `ci-storage` CLI (`tests/common.sh` drives `../ci-storage` directly, `all.sh`
   globs `*.test.sh`) with no container-entrypoint fixture, so building one for a
   one-line change would cost more than it proves.
3. **haproxy accepts the config, and the falsifier is run with its control.** Feed step
   2's generated stanza — wrapped in the same `resolvers res` / `parse-resolv-conf` /
   `hold valid 10s` block the script emits, plus a minimal `global`/`defaults` — to a
   real haproxy binary as `haproxy -c -f <cfg>`, with `$FORWARD_HOST` pointing at a
   deliberately unresolvable name (`.invalid` is reserved for exactly this). Four cells,
   the two config sides differing by the keyword alone:
   - real shape, **with** `init-addr last,libc,none` → accepted, exit 0;
   - real shape, **without** it (delete the keyword from the same file) → *also*
     accepted, exit 0, with only `[WARNING] ... could not resolve address ...,
     disabling server`. This is the shipping shape and the keyword makes no observable
     difference on it;
   - resolvers-stripped control (delete `resolvers res ` from the two `server ` lines,
     keeping the `resolvers res` section), with the keyword → accepted, exit 0;
   - resolvers-stripped control, without it → rejected, exit 1,
     `[ALERT] ... Failed to initialize server(s) addr.`

   Only the last cell fires. The control pair is what makes the real pair's
   non-discrimination interpretable — it proves the check is sensitive rather than blunt.
   Then escalate the real pair to a foreground start (`haproxy -f <cfg> -db`) and observe
   bind-versus-abort directly, since `-c` insensitivity is the other explanation the
   control rules out; both sides stay alive and bound. Do not downgrade the step to a
   grep, and do not report a firing negative side on the real shape — measurement says
   there isn't one. Get a binary via `brew install haproxy` or
   `docker run --rm -v "$PWD:/mnt" haproxy:2.4 haproxy -c -f /mnt/<cfg>`. A local
   haproxy newer than the image's 2.4 is fine here: `init-addr` has been stable
   since 1.7, and this step tests the keyword's semantics, not the image's build.
4. **shellcheck.** `shellcheck docker/ci-runner/root/entrypoint.09-forward.sh` is
   clean (`.shellcheckrc`: `external-sources=true`, `source-path=SCRIPTDIR`). Note
   for the implementer: **shellcheck is not currently on PATH on this machine** —
   install it (`brew install shellcheck`) or run
   `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck <path>` (the image's
   `WorkingDir` is `/mnt`, so relative paths and `.shellcheckrc` resolve). Do not
   report this step as passing without having run it. A string-literal edit is very
   unlikely to introduce a finding, but "unlikely" is not "verified".
5. **Booted-runner check (best-effort).** The ticket's acceptance also wants the
   keyword present in `/etc/haproxy/haproxy.cfg` inside a *booted runner*. The
   honest blocker is local, not CI: `docker/compose.yml` does define a `ci-runner`
   service, but `entrypoint.01-validate.sh` runs first and `exit 1`s on an empty
   `GH_TOKEN`, so bringing the container up far enough to reach
   `entrypoint.09-forward.sh` needs a real GitHub token. Separately, the CI job that
   would cover this, `build-and-boot-containers`, is part of this repo's known-red
   self-hosted set (missing `CI_PAT`/infra) — pre-existing, not caused by this
   change. If a token is available, boot it and capture the generated config as
   evidence. If not, say so plainly and cite steps 2 and 3 as what was actually
   established; never report this step as passed on the strength of the others.

The gating CI signal is the lightweight pair (`ci-storage-tool-test`,
`ci-storage-action-test`) plus the `push-images` build for `ci-runner`. Neither
reads this file, so both passing is a regression check, not proof of the change.

## Out of scope

Payload B (health-check retune, both 2b in `time-loop/sd` and 2c here), Payload C
(the pup/Datadog proof runbook), the compose-recreate cron hazard, the base-image
bake, and the host-side rollout. The last two stay with the requester.
