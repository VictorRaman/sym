defmodule LemonSkills.RegistryGlobalDirsTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Config

  test "loads skills from the compat global skills directory" do
    skill_name = "agents-global-#{System.unique_integer([:positive])}"
    [_primary_dir, compat_dir] = Config.global_skills_dirs()
    skill_dir = Path.join(compat_dir, skill_name)

    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{skill_name}
      description: Global skill from compat global skills dir
      ---

      body
      """
    )

    on_exit(fn ->
      File.rm_rf(skill_dir)
      LemonSkills.refresh()
    end)

    LemonSkills.refresh()

    assert {:ok, entry} = LemonSkills.get(skill_name)
    assert entry.path == skill_dir
  end
end
