defmodule SmmMonitor.FakeFetcher do
  @moduledoc """
  A fetcher whose "live" path returns canned data instead of making an HTTP
  request.

  Lets the worker's live path be tested — that `fetch/2` is called rather
  than `mock_fetch/2` once a platform is configured for live data and has
  credentials — without any network access.
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :fake, display_name: "Fake"

  @impl true
  def ready?(%{credentials: credentials}), do: credentials[:token] != nil

  @impl true
  def fetch(_context, state) do
    mentions = [
      %{
        id: "fake-live-1",
        platform: :fake,
        author: "u/live_path",
        text: "this mention came from the live fetch path",
        url: "https://example.test/fake/1",
        timestamp: DateTime.utc_now()
      }
    ]

    {:ok, mentions, state}
  end
end
