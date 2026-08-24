defmodule MCPElixirSDK.MixProject do
  use Mix.Project

  @version "2.0.0-rc.1"
  @source_url "https://github.com/jmagar/mcp-elixir-sdk"

  def project do
    [
      app: :mcp_elixir_sdk,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:ex_unit]],

      # Hex
      name: "MCP Elixir SDK",
      description:
        "Official-style Elixir SDK for the Model Context Protocol (MCP) — client and server with stdio and Streamable HTTP transports.",
      source_url: @source_url,
      homepage_url: "https://modelcontextprotocol.io",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {MCPElixirSDK.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "MCP 2026-07-28 Specification" =>
          "https://modelcontextprotocol.io/specification/2026-07-28",
        "MCP 2025-11-25 Specification" =>
          "https://modelcontextprotocol.io/specification/2025-11-25",
        "Examples" => "#{@source_url}/tree/main/examples"
      },
      files:
        ~w(lib docs examples usage-rules.md .formatter.exs mix.exs README.md LICENSE CHANGELOG.md) ++
          ~w(conformance/server_handler.ex conformance/client_adapter.exs conformance/server_adapter.exs conformance/*.json conformance/*.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "usage-rules.md": [title: "Usage Rules (AI Agents)"],
        "docs/architecture.md": [title: "Architecture"],
        "docs/dev-tooling.md": [title: "Development Tooling"],
        "docs/sdk-2.0/specifications.md": [title: "2.0 Specifications"],
        "docs/sdk-2.0/contracts.md": [title: "2.0 Contracts"],
        "docs/sdk-2.0/types.md": [title: "2.0 Types"],
        "docs/sdk-2.0/runtime-models.md": [title: "2.0 Runtime Models"],
        "docs/sdk-2.0/meta-plan.md": [title: "2.0 Meta-plan"],
        "docs/adr/0001-target-2025-11-25-defer-2026-07-28.md": [title: "ADR-001"],
        "docs/adr/0002-adopt-2026-07-28-stateless-core-migration.md": [title: "ADR-002"],
        "docs/adr/0003-2.0.0-conformance-scope.md": [title: "ADR-003"],
        "docs/adr/0004-immutable-handler-launch-configuration.md": [
          title: "ADR-004 Immutable Handler Configuration"
        ],
        "docs/adr/0005-consumer-owned-subscription-supervision.md": [
          title: "ADR-005 Subscription Supervision"
        ],
        "docs/adr/0006-no-client-result-cache-in-2.0.md": [
          title: "ADR-006 No Client Result Cache"
        ],
        "docs/adr/0007-dual-protocol-era-support.md": [
          title: "ADR-007 Dual Protocol Support"
        ],
        "docs/adr/0008-dual-version-secure-transports.md": [
          title: "ADR-008 Dual-Version Secure Transports"
        ],
        "docs/adr/0009-mcp-apps-support.md": [
          title: "ADR-009 Stable MCP Apps Support"
        ]
      ],
      groups_for_extras: [
        Guides: [
          "docs/architecture.md",
          "docs/dev-tooling.md",
          "docs/sdk-2.0/specifications.md",
          "docs/sdk-2.0/contracts.md",
          "docs/sdk-2.0/types.md",
          "docs/sdk-2.0/runtime-models.md",
          "docs/sdk-2.0/meta-plan.md"
        ],
        Decisions: [
          "docs/adr/0001-target-2025-11-25-defer-2026-07-28.md",
          "docs/adr/0002-adopt-2026-07-28-stateless-core-migration.md",
          "docs/adr/0003-2.0.0-conformance-scope.md",
          "docs/adr/0004-immutable-handler-launch-configuration.md",
          "docs/adr/0005-consumer-owned-subscription-supervision.md",
          "docs/adr/0006-no-client-result-cache-in-2.0.md",
          "docs/adr/0007-dual-protocol-era-support.md",
          "docs/adr/0008-dual-version-secure-transports.md",
          "docs/adr/0009-mcp-apps-support.md"
        ],
        Reference: ["CHANGELOG.md", "LICENSE", "usage-rules.md"]
      ],
      groups_for_modules: [
        "MCP Apps": ~r/MCP\.Apps/,
        Client: [MCP.Client],
        Server: [
          MCP.Server.Config,
          MCP.Server.Connection,
          MCP.Server.Dispatch,
          MCP.Server.Handler,
          MCP.Server.SubscriptionPublisher,
          MCP.Server.ToolContext
        ],
        Protocol: [
          MCP.Protocol,
          MCP.Protocol.Error,
          MCP.Protocol.Methods,
          MCP.Protocol.Revision,
          MCP.Protocol.LegacyAdapter,
          MCP.Protocol.Legacy.V2025_11_25
        ],
        Capabilities: ~r/MCP\.Protocol\.Capabilities\..*/,
        Messages: ~r/MCP\.Protocol\.Messages\..*/,
        Types: ~r/MCP\.Protocol\.Types\..*/,
        Transport: [
          MCP.Transport,
          MCP.Transport.Stdio,
          MCP.Transport.Stdio.Process,
          MCP.Transport.Stdio.SecurityPolicy,
          MCP.Transport.SSE,
          MCP.Transport.StreamableHTTP.Client,
          MCP.Transport.StreamableHTTP.ResponseReader,
          MCP.Transport.StreamableHTTP.SecurityPolicy,
          MCP.Transport.StreamableHTTP.LegacySessionManager,
          MCP.Transport.StreamableHTTP.Plug
        ]
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["docs/architecture.md", "CHANGELOG.md"]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:elixir_uuid, "~> 1.2"},
      {:erlexec, "~> 2.3"},

      # Optional: Streamable HTTP transport
      {:req, ">= 0.5.0 and < 0.8.0", optional: true},
      {:plug, "~> 1.16", optional: true},
      {:bandit, "~> 1.12.5", optional: true},

      # Dev/test
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [precommit: &precommit/1]
  end

  defp precommit(_args) do
    [
      {"mix", ["format", "--check-formatted"]},
      {"mix", ["compile", "--warnings-as-errors"]},
      {"mix", ["test", "--seed", "0"]},
      {"mix", ["credo", "--strict"]},
      {"mix", ["dialyzer"]},
      {"mix", ["docs", "--warnings-as-errors"]},
      {"elixir", ["scripts/package_smoke.exs"]},
      {"mix", ["hex.audit"]},
      {"mix", ["deps.unlock", "--check-unused"]},
      {"git", ["diff", "--check"]},
      {"jq", ["empty", "conformance/scenarios.json"]},
      {"jq", ["empty", "conformance/compatibility-2025-11-25.json"]},
      {"jq", ["empty", "conformance/mcp-apps-2026-01-26.json"]}
    ]
    |> Enum.each(&run_command!/1)
  end

  defp run_command!({executable, args}) do
    command = Enum.join([executable | args], " ")
    Mix.shell().info([:cyan, "==> ", :reset, command])

    case System.cmd(executable, args, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("#{command} exited with status #{status}")
    end
  end
end
