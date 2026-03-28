defmodule LemonCore.Quality.DocsCheck do
  @moduledoc """
  Lints documentation metadata and link integrity.

  Checks include:
  - catalog entries include ownership and freshness metadata
  - catalog entries point to existing files
  - tracked docs files are registered in the catalog
  - local markdown links resolve to existing files
  """

  alias LemonCore.Quality.DocsCatalog

  @type issue :: %{
          code: atom(),
          message: String.t(),
          path: String.t() | nil
        }

  @type report :: %{
          root: String.t(),
          checked_files: non_neg_integer(),
          issue_count: non_neg_integer(),
          issues: [issue()]
        }

  @doc """
  Runs all documentation quality checks.

  Checks include:
    * Catalog coverage - all tracked docs are in catalog
    * Entry shape validation - all required fields present and valid
    * File existence - catalog entries point to existing files
    * Freshness - documents reviewed within max_age_days
    * Link integrity - local markdown links resolve to existing files

  Returns `{:ok, report}` if no issues found, `{:error, report}` otherwise.

  ## Options
    * `:root` - root directory to check (defaults to current working directory)
    * `:today` - date to use for freshness checks (defaults to today)
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    today = Keyword.get(opts, :today, Date.utc_today())

    {issues, checked_files} = run_checks(root, today)

    report = %{
      root: root,
      checked_files: checked_files,
      issue_count: length(issues),
      issues: Enum.reverse(issues)
    }

    if report.issue_count == 0 do
      {:ok, report}
    else
      {:error, report}
    end
  end

  @spec run_checks(String.t(), Date.t()) :: {[issue()], non_neg_integer()}
  defp run_checks(root, today) do
    case DocsCatalog.load(root: root) do
      {:ok, entries} ->
        issues = []

        issues = check_catalog_coverage(root, entries, issues)
        issues = check_entry_shapes(entries, issues)
        issues = check_entry_files(root, entries, issues)
        issues = check_freshness(today, entries, issues)
        issues = check_links(root, entries, issues)
        issues = check_app_path_references(root, entries, issues)
        issues = check_absorbed_subsystem_narrative(root, entries, issues)

        {issues, length(entries)}

      {:error, message} ->
        {[%{code: :catalog_load_failed, message: message, path: DocsCatalog.catalog_file(root)}], 0}
    end
  end

  @spec check_catalog_coverage(String.t(), [map()], [issue()]) :: [issue()]
  defp check_catalog_coverage(root, entries, issues) do
    tracked_docs = discover_tracked_docs(root)

    catalog_paths =
      entries
      |> Enum.map(&Map.get(&1, :path))
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    Enum.reduce(tracked_docs, issues, fn path, acc ->
      if MapSet.member?(catalog_paths, path) do
        acc
      else
        [
          %{
            code: :missing_catalog_entry,
            message: "Tracked docs file is missing from docs/catalog.exs: #{path}",
            path: path
          }
          | acc
        ]
      end
    end)
  end

  @spec discover_tracked_docs(String.t()) :: [String.t()]
  defp discover_tracked_docs(root) do
    root
    |> Path.join("docs/**/*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(&String.contains?(&1, "/runs/"))
    |> Enum.sort()
  end

  @spec check_entry_shapes([map()], [issue()]) :: [issue()]
  defp check_entry_shapes(entries, issues) do
    Enum.reduce(entries, issues, fn entry, acc ->
      path = Map.get(entry, :path)

      acc
      |> require(entry, :path, &is_binary/1, "expected :path to be a string", path)
      |> require(entry, :owner, &valid_owner?/1, "expected non-empty :owner", path)
      |> require(entry, :last_reviewed, &match?(%Date{}, &1), "expected :last_reviewed to be a Date", path)
      |> require(entry, :max_age_days, &valid_max_age?/1, "expected :max_age_days to be a positive integer", path)
    end)
  end

  defp valid_owner?(owner), do: is_binary(owner) and String.trim(owner) != ""
  defp valid_max_age?(days), do: is_integer(days) and days > 0

  defp require(issues, entry, key, predicate, message, path) do
    case Map.fetch(entry, key) do
      {:ok, value} ->
        if predicate.(value) do
          issues
        else
          [
            %{
              code: :invalid_catalog_entry,
              message: "#{message} (key #{inspect(key)})",
              path: path
            }
            | issues
          ]
        end

      :error ->
        [
          %{
            code: :invalid_catalog_entry,
            message: "#{message} (key #{inspect(key)})",
            path: path
          }
          | issues
        ]
    end
  end

  @spec check_entry_files(String.t(), [map()], [issue()]) :: [issue()]
  defp check_entry_files(root, entries, issues) do
    Enum.reduce(entries, issues, fn entry, acc ->
      path = Map.get(entry, :path)

      if is_binary(path) do
        full_path = Path.join(root, path)

        if File.exists?(full_path) do
          acc
        else
          [
            %{
              code: :missing_doc_file,
              message: "Catalog references missing file: #{path}",
              path: path
            }
            | acc
          ]
        end
      else
        acc
      end
    end)
  end

  @spec check_freshness(Date.t(), [map()], [issue()]) :: [issue()]
  defp check_freshness(today, entries, issues) do
    Enum.reduce(entries, issues, fn entry, acc ->
      with %Date{} = last_reviewed <- Map.get(entry, :last_reviewed),
           max_age when is_integer(max_age) and max_age > 0 <- Map.get(entry, :max_age_days),
           path when is_binary(path) <- Map.get(entry, :path) do
        age = Date.diff(today, last_reviewed)

        if age > max_age do
          [
            %{
              code: :stale_doc,
              message:
                "Document is stale (#{age} days old, max #{max_age}): #{path}. Last reviewed #{Date.to_iso8601(last_reviewed)}",
              path: path
            }
            | acc
          ]
        else
          acc
        end
      else
        _ ->
          acc
      end
    end)
  end

  @spec check_links(String.t(), [map()], [issue()]) :: [issue()]
  defp check_links(root, entries, issues) do
    Enum.reduce(entries, issues, fn entry, acc ->
      case Map.get(entry, :path) do
        path when is_binary(path) ->
          full_path = Path.join(root, path)

          if File.exists?(full_path) do
            broken = broken_links(root, full_path)

            Enum.reduce(broken, acc, fn target, inner_acc ->
              [
                %{
                  code: :broken_link,
                  message: "Broken local markdown link in #{path}: #{target}",
                  path: path
                }
                | inner_acc
              ]
            end)
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  @spec check_app_path_references(String.t(), [map()], [issue()]) :: [issue()]
  defp check_app_path_references(root, entries, issues) do
    Enum.reduce(entries, issues, fn entry, acc ->
      case Map.get(entry, :path) do
        path when is_binary(path) ->
          full_path = Path.join(root, path)

          if File.exists?(full_path) and not historical_doc?(path) do
            missing_paths =
              full_path
              |> File.read!()
              |> extract_app_path_references()
              |> Enum.reject(&app_path_exists?(root, &1))

            Enum.reduce(missing_paths, acc, fn app_path, inner_acc ->
              [
                %{
                  code: :missing_app_path_reference,
                  message:
                    "Doc references missing app path #{app_path}; update it to the absorbed owner path or archive-only location",
                  path: path
                }
                | inner_acc
              ]
            end)
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  @absorbed_subsystem_patterns [
    {"lemon_channels", ~r/`lemon_channels`\s+(external|sibling)\s+app/u},
    {"lemon_router", ~r/`lemon_router`\s+(external|sibling)\s+app/u},
    {"lemon_automation", ~r/`lemon_automation`\s+(external|sibling)\s+app/u},
    {"lemon_mesh", ~r/`lemon_mesh`\s+(external|sibling)\s+app/u},
    {"lemon_channels", ~r/\blemon_channels\b.*compile-time only dependency/u},
    {"lemon_router", ~r/\blemon_router\b.*compile-time only dependency/u},
    {"lemon_automation", ~r/\blemon_automation\b.*compile-time only dependency/u},
    {"lemon_channels", ~r/\*\*lemon_channels\*\*\s+--/u},
    {"lemon_router", ~r/\*\*lemon_router\*\*\s+--/u},
    {"lemon_automation", ~r/\*\*lemon_automation\*\*\s+--/u}
  ]

  @spec check_absorbed_subsystem_narrative(String.t(), [map()], [issue()]) :: [issue()]
  defp check_absorbed_subsystem_narrative(root, entries, issues) do
    Enum.reduce(entries, issues, fn entry, acc ->
      case Map.get(entry, :path) do
        path when is_binary(path) ->
          full_path = Path.join(root, path)

          cond do
            historical_doc?(path) ->
              acc

            not File.exists?(full_path) ->
              acc

            true ->
              content = File.read!(full_path)

              Enum.reduce(@absorbed_subsystem_patterns, acc, fn {name, pattern}, inner_acc ->
                if Regex.match?(pattern, content) do
                  [
                    %{
                      code: :stale_absorbed_subsystem_narrative,
                      message:
                        "Active docs must describe #{name} as an absorbed subsystem or namespace, not a standalone app/dependency",
                      path: path
                    }
                    | inner_acc
                  ]
                else
                  inner_acc
                end
              end)
          end

        _ ->
          acc
      end
    end)
  end

  @spec broken_links(String.t(), String.t()) :: [String.t()]
  defp broken_links(root, file_path) do
    content = File.read!(file_path)

    content
    |> extract_markdown_links()
    |> Enum.filter(&local_link?/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&link_exists?(root, file_path, &1))
    |> Enum.uniq()
  end

  @spec extract_markdown_links(String.t()) :: [String.t()]
  defp extract_markdown_links(content) do
    Regex.scan(~r/\[[^\]]+\]\(([^)]+)\)/, content, capture: :all_but_first)
    |> List.flatten()
  end

  @spec extract_app_path_references(String.t()) :: [String.t()]
  defp extract_app_path_references(content) do
    ~r/apps\/[A-Za-z0-9_-]+(?:\/[A-Za-z0-9_.-]+)*\//
    |> Regex.scan(content)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp app_path_exists?(root, app_path) do
    root
    |> Path.join(app_path)
    |> File.exists?()
  end

  defp historical_doc?(path) do
    String.starts_with?(path, "docs/archive/") or
      String.starts_with?(path, "docs/plans/")
  end

  @spec local_link?(String.t()) :: boolean()
  defp local_link?(link) do
    trimmed = String.trim(link)

    not (
      trimmed == "" or
        String.starts_with?(trimmed, "#") or
        String.starts_with?(trimmed, "http://") or
        String.starts_with?(trimmed, "https://") or
        String.starts_with?(trimmed, "mailto:")
    )
  end

  @spec link_exists?(String.t(), String.t(), String.t()) :: boolean()
  defp link_exists?(root, source_file, link) do
    clean_link =
      link
      |> String.trim()
      |> String.trim_leading("<")
      |> String.trim_trailing(">")
      |> String.split("#")
      |> List.first()

    if clean_link == "" do
      true
    else
      target_path =
        if Path.type(clean_link) == :absolute do
          Path.join(root, String.trim_leading(clean_link, "/"))
        else
          source_file
          |> Path.dirname()
          |> Path.join(clean_link)
        end

      File.exists?(Path.expand(target_path))
    end
  end
end
