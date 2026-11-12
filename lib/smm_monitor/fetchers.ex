defmodule SmmMonitor.Fetchers do
  @moduledoc """
  One front door to every platform's collector, polled or streamed.

  Each entry in `config :smm_monitor, :platforms` has a `:kind`:
  `:poll` (the default) runs a `SmmMonitor.Fetchers.Worker`, and
  `:stream` runs a `SmmMonitor.Fetchers.StreamWorker`. The dashboard asks
  this module for status and never needs to know which is which.
  """

  alias SmmMonitor.Fetchers.{StreamWorker, Worker}

  @doc "The kind of collector a platform uses, from config."
  @spec kind(atom()) :: :poll | :stream
  def kind(platform) do
    :smm_monitor
    |> Application.get_env(:platforms, [])
    |> Keyword.get(platform, [])
    |> Keyword.get(:kind, :poll)
  end

  @doc "The worker module for a kind."
  @spec worker(:poll | :stream) :: module()
  def worker(:stream), do: StreamWorker
  def worker(_poll), do: Worker

  @doc "A platform's status, or `:unavailable` if its worker is not running."
  @spec status(atom()) :: map() | :unavailable
  def status(platform), do: worker(kind(platform)).status(platform)

  @doc "Asks a platform to collect now (or, for a stream, to reconnect now)."
  @spec poll_now(atom()) :: :ok
  def poll_now(platform), do: worker(kind(platform)).poll_now(platform)
end
