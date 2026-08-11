# Development Tooling

The checked-in `.tool-versions` selects Erlang/OTP 27.2.3 and Elixir
1.18.4-otp-27. The package supports Elixir `~> 1.17`; CI exercises the oldest
supported line, the pinned development line, and the current Elixir/OTP line.

## Local gates

Run these from the repository root:

```bash
mix deps.get
mix precommit
```

`mix precommit` is the canonical local gate. It runs the following checks in
the same deterministic order on every invocation; CI keeps them as separate
steps so a hosted failure names the failed check directly:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --seed 0
mix credo --strict
mix dialyzer
mix docs
mix hex.build
mix hex.audit
mix deps.unlock --check-unused
git diff --check
jq empty conformance/scenarios.json
jq empty conformance/compatibility-2025-11-25.json
```

Do not use sleeps to coordinate process tests. Start owned processes with
`start_supervised!/1`, synchronize mailboxes with `_ = :sys.get_state(pid)`,
and assert termination with monitors.

## Official conformance

The harness is pinned to `@modelcontextprotocol/conformance@0.2.0-alpha.11`.
Select the exact revision and start the server adapter:

```bash
MCP_CONFORMANCE_PROTOCOL_VERSION=2025-11-25 \
  mix run --no-halt conformance/server_adapter.exs 43001
```

Then run both server release denominators:

```bash
npm ci --ignore-scripts
npx --no-install conformance server \
  --url http://127.0.0.1:43001/mcp \
  --requirements 2026-07-28

npx --no-install conformance server \
  --url http://127.0.0.1:43001/mcp \
  --requirements 2025-11-25
```

Client scenarios invoke the checked-in adapter, for example:

```bash
npx --no-install conformance client \
  --command 'mix run conformance/client_adapter.exs' \
  --scenario sep-2322-client-request-state \
  --spec-version 2026-07-28
```

For the frozen November requirement set, explicitly pass the wire revision to
the adapter because harness `0.2.0-alpha.11` does not forward the requirement
revision to child-process environments:

```bash
npx --no-install conformance client \
  --command 'env MCP_CONFORMANCE_PROTOCOL_VERSION=2025-11-25 ERL_LIBS=_build/dev/lib elixir conformance/client_adapter.exs' \
  --requirements 2025-11-25
```

`conformance/scenarios.json` records the 2026 release matrix and
the two `conformance/compatibility-*.json` files record the legacy evidence and
limitations. Authorization-profile scenarios remain outside the SDK transport
scope. Do not replace the pin with `latest` in release evidence.

## Package inspection

`mix hex.build` must succeed without generated docs or build output entering the
archive. Inspect the resulting tarball before release and verify the README,
license, changelog, full `docs/` package, and conformance ledger are present.

## Actual-Unraid stdio cleanup probe

The release probe is `test/runtime/unraid_stdio_cleanup.exs`, run as:

```bash
mix run --no-start test/runtime/unraid_stdio_cleanup.exs -- test/support/adversarial_stdio_server.exs
```

`--no-start` is required when `MCP_ERLEXEC_ALLOW_ROOT=1`: erlexec reads its root
configuration at application start, so the probe must configure it before the
application tree comes up.

On 2026-08-10 it was run from the built Hex archive on an Unraid development
host, Linux `6.18.38-Unraid`, inside a disposable `elixir:1.18.4` container with Docker
`--init`. The host has no native Mix installation.

The first run exposed that `/proc/<pid>/task/<pid>/children` alone did not find
a descendant that created its own process group. The internal stdio process
owner now cross-checks the complete `/proc/*/stat` parent table before shutdown,
capturing each descendant's parent and start time from a single read so a PID
recycled mid-scan cannot be mistaken for a descendant. After rebuilding the
archive, the probe reported:

```text
unraid stdio cleanup passed root_pid=335 root_pgid=335 descendant_pid=415 descendant_pgid=415
```

The separate process-group IDs are significant: cleanup did not pass merely
because erlexec signalled the root command's process group. The temporary
container, package directory, and images pulled solely for the probe were
removed afterward.

## Sandboxed-upstream stdio probe

`test/runtime/microsandbox_stdio_roundtrip.exs` runs a real third-party MCP
server inside a [microsandbox](https://docs.microsandbox.dev/) microVM and
drives it through this SDK's stdio transport:

```bash
mix run --no-start test/runtime/microsandbox_stdio_roundtrip.exs
```

Requires `msb` on `PATH` (or `MCP_MSB_BIN`) and a KVM-capable host. The first
run needs network access: it creates the sandbox and installs
`@modelcontextprotocol/server-everything` into it. Later runs reuse the warm
sandbox. `MCP_MSB_SANDBOX` and `MCP_MSB_IMAGE` override the defaults.

The probe exists because three properties cannot be shown by the unit suite:

1. A sandbox is only a different `:command`/`:args`. The transport is unchanged,
   which is what makes `SecurityPolicy`'s absolute-executable-plus-argv rule
   compatible with containment wrappers.
2. Normal close reaps the host launcher **and** the process inside the guest,
   which the host-side `/proc` descendant sweep cannot see.
3. A SIGKILLed BEAM — where `terminate/2` never runs — also leaves no orphan on
   either side. `unraid_stdio_cleanup.exs` only covers the close path.

It also pins two facts that are easy to regress into:

- The shared `exec-port` must **survive** one upstream closing. erlexec
  registers one per BEAM (`deps/erlexec/src/exec.erl:544`), so tearing it down
  with a single upstream would kill every sibling upstream.
- The microVM itself is **not** reclaimed by any teardown path. `msb create` is
  persistent by design, so a consumer must stop it explicitly and use
  `--idle-timeout` as the backstop for the SIGKILL case. The probe asserts the
  VM is still running at the end so the obligation stays visible.

On 2026-08-10 a run on Linux 6.17 with nested KVM reported:

```text
roundtrip passed server=mcp-servers/everything v2.0.0 era=2025-11-25 tools=13 sum="The sum of 17 and 25 is 42."
normal close passed launcher=3781715 reaped, shared exec_port=3781658 survived
sigkill cleanup passed beam=3781818 launcher=3781990 exec_port=3781936
microvm survived both teardowns; consumers must stop it explicitly
```

The negotiated `2025-11-25` is incidental evidence for the fallback ladder: the
reference server has no `2026-07-28` support, so the session was only reachable
by walking down to a shared revision. Host teardown after SIGKILL is not
instantaneous — `exec-port` observes a broken pipe rather than a signal — so the
orphan assertions allow 60s.

Every buffered `msb` call in the probe redirects stdin from `/dev/null`.
Buffered `msb exec` drains stdin to EOF before running anything and an Erlang
port never closes the child's stdin, so the pair deadlocks; the MCP launch path
avoids this by using `msb exec --stream`.
