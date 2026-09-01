defmodule MCP.SelectReqCompat do
  @moduledoc false

  @supported_versions ~w(0.6.1 0.7.2)
  @constraint ~r/\{:req, ">= 0\.6\.1 and < 0\.8\.0", optional: true\}/

  def run!([version]) when version in @supported_versions do
    mix_file = "mix.exs"
    source = File.read!(mix_file)

    replacement = ~s({:req, "== #{version}", optional: true})
    updated = Regex.replace(@constraint, source, replacement)

    if updated == source do
      raise "expected Req compatibility constraint was not found in mix.exs"
    end

    File.write!(mix_file, updated)
  end

  def run!(_args) do
    raise "expected one supported Req version: #{Enum.join(@supported_versions, ", ")}"
  end
end

MCP.SelectReqCompat.run!(System.argv())
