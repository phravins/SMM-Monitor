defmodule SmmMonitor.Fetchers.PlatformSupervisor do
  @moduledoc """
  A supervisor wrapping a single platform's worker.

  One supervisor per platform is the point of the whole layer: if the
  YouTube worker crashes in a loop, the restarts are counted against *this*
  supervisor, and only this supervisor gives up. Reddit keeps polling, the
  processing layer keeps its ETS table, and the dashboard keeps rendering.

  `max_restarts` is generous because a flapping API is a normal condition
  for a monitoring tool, not a reason to take the platform offline.
  """

  use Supervisor

  alias SmmMonitor.Fetchers.Worker

  @max_restarts 10
  @max_seconds 60

  def start_link(opts) do
    platform = Keyword.fetch!(opts, :platform)
    Supervisor.start_link(__MODULE__, opts, name: name(platform))
  end

  @doc "Registered name for a platform's supervisor."
  @spec name(atom()) :: atom()
  def name(platform) do
    Module.concat(__MODULE__, platform |> Atom.to_string() |> Macro.camelize())
  end

  @doc """
  Child spec with a per-platform id, so several of these can live side by
  side under `SmmMonitor.Fetchers.Supervisor`.
  """
  def child_spec(opts) do
    platform = Keyword.fetch!(opts, :platform)

    %{
      id: name(platform),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    children = [
      {Worker,
       module: Keyword.fetch!(opts, :module),
       opts: Keyword.get(opts, :opts, []),
       interval_ms: Keyword.get(opts, :interval_ms, SmmMonitor.config(:poll_interval_ms, 30_000))}
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end
end
