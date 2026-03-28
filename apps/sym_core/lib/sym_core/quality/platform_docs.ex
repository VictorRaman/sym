defmodule LemonCore.Quality.PlatformDocs do
  @moduledoc """
  Renders and validates the generated platform-tier section in the
  platform tiers document.
  """

  alias LemonCore.Quality.PlatformManifest

  @doc_relative_path "docs/platform_tiers.md"
  @section_start "<!-- platform_manifest:start -->"
  @section_end "<!-- platform_manifest:end -->"

  @type issue :: %{
          code: atom(),
          message: String.t(),
          path: String.t() | nil
        }

  @type report :: %{
          root: String.t(),
          issue_count: non_neg_integer(),
          issues: [issue()]
        }

  @spec doc_relative_path() :: String.t()
  def doc_relative_path, do: @doc_relative_path

  @spec render_manifest_markdown() :: String.t()
  def render_manifest_markdown do
    header = """
    | App | Tier | Status | Profiles | Owner | Keep Reason |
    | --- | --- | --- | --- | --- | --- |
    """

    rows =
      PlatformManifest.entries()
      |> Enum.sort_by(&Atom.to_string(&1.id))
      |> Enum.map(fn entry ->
        profiles =
          case entry.profiles do
            [] -> "*(none)*"
            list -> Enum.map_join(list, ", ", &"`#{&1}`")
          end

        "| `#{entry.id}` | `#{entry.tier}` | `#{entry.status}` | #{profiles} | #{entry.owner} | #{entry.keep_reason} |"
      end)

    Enum.join([header | rows], "\n")
  end

  @spec replace_generated_section(String.t(), String.t()) :: {:ok, String.t()} | {:error, issue()}
  def replace_generated_section(content, rendered_markdown \\ render_manifest_markdown()) do
    replacement = Enum.join([@section_start, rendered_markdown, @section_end], "\n")
    pattern = ~r/#{Regex.escape(@section_start)}\n.*?\n#{Regex.escape(@section_end)}/s

    if Regex.match?(pattern, content) do
      {:ok, Regex.replace(pattern, content, replacement)}
    else
      {:error,
       %{
         code: :missing_platform_doc_markers,
         message:
           "Platform tiers doc is missing generated-section markers: #{@section_start} / #{@section_end}",
         path: @doc_relative_path
       }}
    end
  end

  @spec write(String.t()) :: :ok | {:error, issue()}
  def write(root) do
    case generate(root) do
      {:ok, _existing, generated} ->
        case File.write(doc_path(root), generated) do
          :ok -> :ok
          {:error, reason} -> {:error, read_or_write_issue(:write_failed, "write", reason)}
        end

      {:error, issue} ->
        {:error, issue}
    end
  end

  @spec check(String.t()) :: {:ok, report()} | {:error, report()}
  def check(root) do
    case generate(root) do
      {:ok, existing, generated} ->
        if existing == generated do
          {:ok, report(root, [])}
        else
          {:error,
           report(root, [
             %{
               code: :stale_platform_doc,
               message: "Platform tiers doc is stale. Run `mix lemon.platform.docs`.",
               path: @doc_relative_path
             }
           ])}
        end

      {:error, issue} ->
        {:error, report(root, [issue])}
    end
  end

  @spec generate(String.t()) :: {:ok, String.t(), String.t()} | {:error, issue()}
  def generate(root) do
    path = doc_path(root)

    with {:ok, existing} <- File.read(path),
         {:ok, generated} <- replace_generated_section(existing) do
      {:ok, existing, generated}
    else
      {:error, %{} = issue} ->
        {:error, issue}

      {:error, reason} ->
        {:error, read_or_write_issue(:read_failed, "read", reason)}
    end
  end

  defp doc_path(root), do: Path.join(root, @doc_relative_path)

  defp read_or_write_issue(code, action, reason) do
    %{
      code: code,
      message:
        "Failed to #{action} #{@doc_relative_path}: #{:file.format_error(reason) |> to_string()}",
      path: @doc_relative_path
    }
  end

  defp report(root, issues) do
    %{
      root: root,
      issue_count: length(issues),
      issues: issues
    }
  end
end
