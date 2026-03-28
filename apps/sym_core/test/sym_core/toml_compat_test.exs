defmodule LemonCore.TomlCompatTest do
  use ExUnit.Case, async: false

  alias LemonCore.TomlCompat

  test "decode/1 returns parsed maps for valid TOML" do
    assert {:ok, %{"defaults" => %{"provider" => "anthropic"}}} =
             TomlCompat.decode("""
             [defaults]
             provider = "anthropic"
             """)
  end

  test "decode/1 returns errors for invalid TOML" do
    assert {:error, _reason} =
             TomlCompat.decode("""
             [defaults
             provider = "anthropic"
             """)
  end

  test "decode_file/1 returns parsed maps for valid TOML files" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "toml_compat_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    path = Path.join(tmp_dir, "config.toml")

    File.write!(path, """
    [defaults]
    model = "claude-sonnet-4"
    """)

    assert {:ok, %{"defaults" => %{"model" => "claude-sonnet-4"}}} =
             TomlCompat.decode_file(path)
  end
end
