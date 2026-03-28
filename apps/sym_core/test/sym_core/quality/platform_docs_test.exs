defmodule LemonCore.Quality.PlatformDocsTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.PlatformDocs

  describe "render_manifest_markdown/0" do
    test "renders only the reduced kept apps" do
      markdown = PlatformDocs.render_manifest_markdown()

      assert markdown =~ "| `lemon_core` |"
      assert markdown =~ "| `ai` |"
      assert markdown =~ "| `coding_agent` |"
      assert markdown =~ "| `lemon_gateway` |"
      assert markdown =~ "| `lemon_control_plane` |"

      refute markdown =~ "| `market_intel` |"
      refute markdown =~ "| `coding_agent_ui` |"
      refute markdown =~ "| `lemon_mcp` |"
      refute markdown =~ "| `lemon_router` |"
      refute markdown =~ "| `lemon_channels` |"
    end

    test "renders rows in sorted app order" do
      apps =
        PlatformDocs.render_manifest_markdown()
        |> String.split("\n", trim: true)
        |> Enum.drop(2)
        |> Enum.map(fn row ->
          [_, app | _rest] = Regex.run(~r/^\| `([^`]+)` \|/, row)
          app
        end)

      assert apps == Enum.sort(apps)
    end
  end

  describe "replace_generated_section/2" do
    test "is idempotent" do
      content = """
      # Platform Tiers

      <!-- platform_manifest:start -->
      stale
      <!-- platform_manifest:end -->
      """

      assert {:ok, once} = PlatformDocs.replace_generated_section(content)
      assert {:ok, twice} = PlatformDocs.replace_generated_section(once)
      assert once == twice
    end
  end

  describe "check/1" do
    test "reports stale platform docs" do
      tmp_dir = create_tmp_repo()

      try do
        write_doc_fixture(tmp_dir, """
        # Platform Tiers

        <!-- platform_manifest:start -->
        stale
        <!-- platform_manifest:end -->
        """)

        assert {:error, report} = PlatformDocs.check(tmp_dir)
        assert report.issue_count == 1
        assert [%{code: :stale_platform_doc}] = report.issues
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "passes when generated section is current" do
      tmp_dir = create_tmp_repo()

      try do
        write_doc_fixture(tmp_dir, """
        # Platform Tiers

        <!-- platform_manifest:start -->
        placeholder
        <!-- platform_manifest:end -->
        """)

        :ok = PlatformDocs.write(tmp_dir)
        assert {:ok, report} = PlatformDocs.check(tmp_dir)
        assert report.issue_count == 0
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  defp create_tmp_repo do
    tmp_dir =
      Path.join(System.tmp_dir!(), "platform_docs_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, "docs"))
    tmp_dir
  end

  defp write_doc_fixture(root, content) do
    File.write!(Path.join(root, "docs/platform_tiers.md"), content)
  end
end
