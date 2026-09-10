defmodule SmmMonitor.Clients.Seed do
  @moduledoc """
  Builds the client list for an install that doesn't have one yet.

  Two situations look identical from the database's point of view — an
  empty `clients` table — and both are handled here:

    * **An upgrade.** The install was tracking one brand through
      `SMM_KEYWORDS` and the old JSON config file. Those settings become
      a single client, named from the brand term, so monitoring carries
      on across the upgrade without anyone re-typing anything.

    * **A fresh install.** No file, no env vars: one client built from
      the packaged defaults, so the dashboard has something to show and
      the config screen has something to edit.

  ## Why the old config file is still read

  It is where the runtime-editable brand terms lived, and it outranks the
  environment for exactly that reason: someone who changed their brand
  terms from the config screen last week meant those, not whatever
  `SMM_KEYWORDS` said at deploy time.

  The file is never written to again. It stays on disk untouched, which
  makes rolling back to the previous version a matter of downgrading the
  release rather than restoring a backup.
  """

  require Logger

  alias SmmMonitor.{Client, Mention}
  alias SmmMonitor.Config.Store, as: LegacyStore

  @doc """
  The clients to start with, newest information winning.

  Always returns at least one client, because a monitoring tool with
  nothing to monitor is a blank screen with no way out of it.
  """
  @spec build(keyword()) :: [Client.t()]
  def build(opts \\ []) do
    legacy = legacy_settings(opts)
    keywords = Client.normalize(legacy[:keywords])
    subreddits = Client.normalize(legacy[:subreddits])

    attrs = %{
      # The holding client id, so mentions the migration backfilled land
      # in the same client as the brand they were actually collected for
      # — rather than sitting in a second, empty "Unassigned".
      id: Mention.default_client_id(),
      name: name_from(keywords),
      keywords: keywords,
      subreddits: subreddits
    }

    case Client.new(attrs) do
      {:ok, client} ->
        log_seed(client, legacy[:source])
        [client]

      {:error, _reason} ->
        # No keywords anywhere: still produce a client, so the config
        # screen has a row to edit rather than an empty list.
        {:ok, placeholder} =
          Client.new(%{
            id: Mention.default_client_id(),
            name: "Unassigned",
            keywords: ["realoffice"]
          })

        Logger.warning(
          "clients: no brand terms found in the config file or SMM_KEYWORDS; created a " <>
            "placeholder client. Edit it from the config screen (c)."
        )

        [placeholder]
    end
  end

  @doc """
  A client name derived from the brand terms.

  The longest term wins over the first: "real office" reads as a company
  name where "realoffice" reads as a handle, and this is what a person
  sees at the top of their dashboard.

      iex> SmmMonitor.Clients.Seed.name_from(["realoffice", "real office"])
      "Real office"
      iex> SmmMonitor.Clients.Seed.name_from([])
      "Unassigned"
  """
  @spec name_from([String.t()]) :: String.t()
  def name_from([]), do: "Unassigned"

  def name_from(keywords) do
    keywords
    |> Enum.max_by(&String.length/1)
    |> String.trim()
    |> String.capitalize()
  end

  # The config file outranks the environment: it holds what someone
  # actually chose, where the env holds what was deployed.
  defp legacy_settings(opts) do
    case LegacyStore.load(Keyword.get(opts, :legacy_path) || LegacyStore.default_path()) do
      {:ok, stored} ->
        [
          keywords: stored[:keywords] || env_keywords(opts),
          subreddits: stored[:subreddits] || env_subreddits(),
          source: :config_file
        ]

      _missing_or_broken ->
        [keywords: env_keywords(opts), subreddits: env_subreddits(), source: :environment]
    end
  end

  defp env_keywords(opts) do
    Keyword.get(opts, :keywords) || SmmMonitor.config(:keywords, [])
  end

  defp env_subreddits do
    :smm_monitor
    |> Application.get_env(SmmMonitor.Fetchers.Reddit, [])
    |> Keyword.get(:subreddits, [])
  end

  defp log_seed(client, source) do
    Logger.info(
      "clients: no clients stored yet - created \"#{client.name}\" from the previous " <>
        "single-brand settings (#{source}): #{Enum.join(client.keywords, ", ")}"
    )
  end
end
