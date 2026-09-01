defmodule MCP.ValidateConformanceLedgers do
  @moduledoc false

  @harness "@modelcontextprotocol/conformance@0.2.0-alpha.11"
  @legacy_scenarios ~w(tools_call elicitation-sep1034-client-defaults)
  @legacy_excluded_scenarios ["initialize"]
  @legacy_partial_scenarios ["sse-retry"]

  def run! do
    modern = decode!("conformance/scenarios.json")
    legacy = decode!("conformance/compatibility-2025-11-25.json")

    require_equal!(modern["harness"], @harness, "modern harness pin")
    require_equal!(modern["protocolVersion"], "2026-07-28", "modern protocol version")
    validate_modern_scenarios!(modern["scenarios"])
    validate_exclusions!(modern["excludedProfiles"])

    require_equal!(legacy["harness"], @harness, "legacy harness pin")
    require_equal!(legacy["protocolVersion"], "2025-11-25", "legacy protocol version")
    require_equal!(legacy["server"]["status"], "passed", "legacy server status")
    require_equal!(legacy["client"]["status"], "incomplete", "legacy client status")
    require_present!(legacy["client"]["releaseBlocker"], "legacy release blocker")

    validate_legacy_scenarios!(legacy["client"]["requiredNonAuthorizationScenarios"])
    IO.puts("conformance ledger validation passed")
  end

  defp decode!(path) do
    path |> File.read!() |> JSON.decode!()
  end

  defp validate_modern_scenarios!(scenarios) when is_list(scenarios) and scenarios != [] do
    invalid =
      Enum.reject(scenarios, fn scenario ->
        scenario["status"] in ["passed", "excluded"] and
          (scenario["status"] != "excluded" or present?(scenario["exclusionReason"]))
      end)

    if invalid != [],
      do: raise("modern ledger has invalid scenario statuses: #{inspect(invalid)}")
  end

  defp validate_modern_scenarios!(_), do: raise("modern ledger has no scenarios")

  defp validate_exclusions!(profiles) when is_list(profiles) do
    if Enum.any?(profiles, &(not present?(&1["exclusionReason"]))) do
      raise "modern ledger has an exclusion without a reason"
    end
  end

  defp validate_exclusions!(_), do: raise("modern excludedProfiles must be a list")

  defp validate_legacy_scenarios!(scenarios) when is_list(scenarios) do
    passed = for %{"name" => name, "status" => "passed"} <- scenarios, do: name
    excluded = for %{"name" => name, "status" => "excluded"} <- scenarios, do: name
    partial = for %{"name" => name, "status" => "partial"} <- scenarios, do: name

    require_equal!(Enum.sort(passed), Enum.sort(@legacy_scenarios), "legacy passing scenarios")
    require_equal!(excluded, @legacy_excluded_scenarios, "legacy excluded scenarios")

    require_equal!(
      Enum.sort(partial),
      Enum.sort(@legacy_partial_scenarios),
      "legacy partial scenarios"
    )

    Enum.each(scenarios, fn scenario ->
      if scenario["status"] in ["partial", "excluded"] and
           not present?(scenario["limitation"]) do
        raise "legacy non-passing scenario #{scenario["name"]} has no limitation"
      end
    end)
  end

  defp validate_legacy_scenarios!(_), do: raise("legacy scenarios must be a list")

  defp require_equal!(actual, expected, _label) when actual == expected, do: :ok

  defp require_equal!(actual, expected, label) do
    raise "#{label} mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp require_present!(value, _label) when is_binary(value) and value != "", do: :ok
  defp require_present!(_value, label), do: raise("#{label} is missing")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end

MCP.ValidateConformanceLedgers.run!()
