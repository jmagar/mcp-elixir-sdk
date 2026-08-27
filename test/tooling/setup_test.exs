defmodule MCP.Tooling.SetupTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @setup Path.join(@repo_root, "bin/setup")

  test "bootstrap is executable, parses, and invokes every pinned setup step" do
    assert {_output, 0} = System.cmd("test", ["-x", @setup], stderr_to_stdout: true)
    assert {_output, 0} = System.cmd("bash", ["-n", @setup], stderr_to_stdout: true)

    fixture_dir = temporary_directory!()
    log = Path.join(fixture_dir, "mise.log")
    fake_mise = Path.join(fixture_dir, "mise")

    File.write!(fake_mise, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$MISE_TEST_LOG\"\n")
    File.chmod!(fake_mise, 0o755)

    path = fixture_dir <> ":" <> System.fetch_env!("PATH")

    assert {_output, 0} =
             System.cmd("bash", [@setup],
               cd: @repo_root,
               env: [{"MISE_TEST_LOG", log}, {"PATH", path}],
               stderr_to_stdout: true
             )

    assert File.read!(log) ==
             "install\n" <>
               "exec -- mix local.hex --force\n" <>
               "exec -- mix local.rebar --force\n" <>
               "exec -- mix deps.get\n" <>
               "exec -- mix --version\n"
  end

  test "bootstrap fails clearly when mise is unavailable" do
    assert {output, 1} =
             System.cmd("/bin/bash", [@setup],
               cd: @repo_root,
               env: [{"PATH", "/usr/bin:/bin"}],
               stderr_to_stdout: true
             )

    assert output =~ "mise is required"
  end

  test "bootstrap fails before installation when any gate dependency is unavailable" do
    for {missing, present} <- [{"git", "jq"}, {"jq", "git"}] do
      fixture_dir = temporary_directory!()
      fake_mise = Path.join(fixture_dir, "mise")
      mise_log = Path.join(fixture_dir, "mise.log")

      File.write!(fake_mise, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$MISE_TEST_LOG\"\n")
      File.chmod!(fake_mise, 0o755)
      File.ln_s!(System.find_executable(present), Path.join(fixture_dir, present))
      File.ln_s!(System.find_executable("dirname"), Path.join(fixture_dir, "dirname"))

      assert {output, 1} =
               System.cmd("/bin/bash", [@setup],
                 cd: @repo_root,
                 env: [{"MISE_TEST_LOG", mise_log}, {"PATH", fixture_dir}],
                 stderr_to_stdout: true
               )

      assert output =~ "#{missing} is required by the canonical mix precommit gate"
      refute File.exists?(mise_log)
    end
  end

  defp temporary_directory! do
    path =
      Path.join(
        System.tmp_dir!(),
        "mcp-elixir-sdk-setup-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
