defmodule MCP.PackageSmoke do
  @moduledoc false

  def run! do
    root = File.cwd!()
    temp_root = package_temp_root()
    package_root = Path.join(temp_root, "package")

    File.mkdir_p!(temp_root)

    try do
      run!("mix", ["hex.build", "--unpack", "--output", package_root], root)
      assert_packaged_files!(package_root)
      run!("mix", ["deps.get", "--only", "prod"], package_root, [{"MIX_ENV", "prod"}])

      run!(
        "mix",
        ["compile", "--warnings-as-errors"],
        package_root,
        [{"MIX_ENV", "prod"}]
      )

      run!(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          quickstart_assertion()
        ],
        package_root,
        [{"MIX_ENV", "prod"}]
      )

      IO.puts("package smoke passed from #{package_root}")
    after
      File.rm_rf!(temp_root)
    end
  end

  defp assert_packaged_files!(package_root) do
    for relative <- [
          "README.md",
          "LICENSE",
          "CHANGELOG.md",
          "usage-rules.md",
          "docs/dev-tooling.md",
          "conformance/scenarios.json",
          "examples/quickstart_server.exs"
        ] do
      path = Path.join(package_root, relative)
      if not File.regular?(path), do: raise("package is missing #{relative}")
    end

    generated_dependency_trees = Path.wildcard(Path.join(package_root, "**/node_modules"))

    if generated_dependency_trees != [] do
      raise("package contains generated dependency trees: #{inspect(generated_dependency_trees)}")
    end

    for relative <- [
          "conformance/apps_browser_adapter.exs",
          "conformance/apps_browser_handler.ex",
          "conformance/apps_browser_interop.mjs",
          "conformance/browser/package-lock.json"
        ] do
      if File.exists?(Path.join(package_root, relative)) do
        raise("package contains browser-only interoperability fixture #{relative}")
      end
    end
  end

  defp run!(command, args, directory, extra_env \\ []) do
    IO.puts("==> (package) #{Enum.join([command | args], " ")}")

    env = merge_env(extra_env)

    case System.cmd(command, args,
           cd: directory,
           env: env,
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {_, status} -> raise("#{command} #{Enum.join(args, " ")} exited with status #{status}")
    end
  end

  defp merge_env(extra_env) do
    base =
      System.get_env()
      |> Map.take(["PATH", "HOME", "MIX_HOME", "HEX_HOME"])
      |> Map.to_list()

    base
    |> Map.new()
    |> Map.put("ERL_FLAGS", "+S 2:2 +A 2")
    |> Map.merge(Map.new(extra_env))
    |> Map.to_list()
  end

  defp quickstart_assertion do
    ~S|Code.require_file("examples/quickstart_server.exs"); alias MCP.Examples.QuickstartServer.Handler; alias MCP.Server.ToolContext; {:ok, %{}} = Handler.init([]); {:ok, [%{"type" => "text", "text" => "42"}]} = Handler.handle_call_tool("add", %{"a" => 20, "b" => 22}, %ToolContext{}, %{})|
  end

  defp package_temp_root do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "mcp-elixir-sdk-package-smoke-#{suffix}")
  end
end

MCP.PackageSmoke.run!()
