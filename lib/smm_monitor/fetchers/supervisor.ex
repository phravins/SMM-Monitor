defmodule SmmMonitor.Fetchers.Supervisor do
  @moduledoc """
  Supervises one `PlatformSupervisor` per configured platform.

      SmmMonitor.Fetchers.Supervisor          (one_for_one)
      ├── PlatformSupervisor(:reddit)    → Worker(:reddit)
      ├── PlatformSupervisor(:youtube)   → Worker(:youtube)
      ├── PlatformSupervisor(:twitter)   → Worker(:twitter)
      └── PlatformSupervisor(:instagram) → Worker(:instagram)

  Children come from `config :smm_monitor, :platforms`, so adding a platform
  never means touching this module.
  """

  use Supervisor

  alias SmmMonitor.Fetchers.PlatformSupervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  @doc "The platform supervisor child specs, derived from config."
  @spec children() :: [Supervisor.child_spec()]
  def children do
    :smm_monitor
    |> Application.get_env(:platforms, [])
    |> Enum.filter(fn {_platform, opts} -> Keyword.get(opts, :enabled, true) end)
    |> Enum.map(fn {platform, opts} ->
      {PlatformSupervisor,
       platform: platform, module: Keyword.fetch!(opts, :module), opts: Keyword.get(opts, :opts, [])}
    end)
  end
end
