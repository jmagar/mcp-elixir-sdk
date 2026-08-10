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
Start the server adapter:

```bash
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

`conformance/scenarios.json` records the 2026 release matrix and
`conformance/compatibility-2025-11-25.json` records the legacy compatibility
denominator. Authorization-profile scenarios remain outside the SDK transport
scope. Do not replace the pin with `latest` in release evidence.

## Package inspection

`mix hex.build` must succeed without generated docs or build output entering the
archive. Inspect the resulting tarball before release and verify the README,
license, changelog, full `docs/` package, and conformance ledger are present.
