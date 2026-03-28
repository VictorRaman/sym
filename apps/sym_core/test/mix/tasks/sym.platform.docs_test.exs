defmodule Mix.Tasks.Lemon.Platform.DocsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Platform.Docs, as: PlatformDocsTask

  setup do
    Mix.Task.reenable("lemon.platform.docs")

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_platform_docs_task_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "docs"))

    on_exit(fn ->
      Mix.Task.reenable("lemon.platform.docs")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "--check passes when platform docs are current", %{tmp_dir: tmp_dir} do
    write_platform_doc(tmp_dir, """
    # Platform Tiers

    <!-- platform_manifest:start -->
    placeholder
    <!-- platform_manifest:end -->
    """)

    capture_io(fn ->
      PlatformDocsTask.run(["--root", tmp_dir])
    end)

    output =
      capture_io(fn ->
        PlatformDocsTask.run(["--check", "--root", tmp_dir])
      end)

    assert output =~ "[ok] platform docs are up to date"
  end

  test "--check fails when platform docs are stale", %{tmp_dir: tmp_dir} do
    write_platform_doc(tmp_dir, """
    # Platform Tiers

    <!-- platform_manifest:start -->
    stale
    <!-- platform_manifest:end -->
    """)

    assert_raise Mix.Error, ~r/Platform tiers doc is stale/, fn ->
      capture_io(fn ->
        PlatformDocsTask.run(["--check", "--root", tmp_dir])
      end)
    end
  end

  defp write_platform_doc(root, content) do
    File.write!(Path.join(root, "docs/platform_tiers.md"), content)
  end
end
