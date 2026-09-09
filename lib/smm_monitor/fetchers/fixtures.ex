defmodule SmmMonitor.Fetchers.Fixtures do
  @moduledoc """
  Fake but plausible mentions, so the dashboard is useful with no API keys.

  This is what makes mock mode the default: `mix smm.tui` on a fresh clone
  shows a populated, moving dashboard. The first poll backfills a few hours
  of history; later polls trickle in a mention or two so the UI visibly
  updates while you watch it.
  """

  @backfill_count 18
  @backfill_span_ms :timer.hours(6)

  # Templates carry a rough sentiment intent so the sentiment bar shows a
  # realistic mix rather than everything landing on neutral.
  @templates [
    {:positive, "Honestly {brand} has been excellent this quarter — support is really responsive"},
    {:positive, "{brand} saved us hours this week. Fantastic tool, would recommend"},
    {:positive, "just switched to {brand} and the onboarding was smooth. very impressed"},
    {:positive, "shout out to the {brand} team, quality work and fast turnaround"},
    {:positive, "{brand} dashboards are brilliant, best we have used"},
    {:negative, "{brand} was down again this morning. third outage this month, frustrating"},
    {:negative, "not great — {brand} kept crashing on mobile for me"},
    {:negative, "anyone else finding {brand} slow today? seeing errors on every upload"},
    {:negative, "cancelled our {brand} plan, overpriced for what you get"},
    {:negative, "{brand} support has been terrible, still waiting on a refund"},
    {:neutral, "does {brand} integrate with the usual scheduling tools? asking for a client"},
    {:neutral, "comparing {brand} and the alternatives for a client rollout next month"},
    {:neutral, "posted a walkthrough of our {brand} setup, link in bio"},
    {:neutral, "{brand} pricing page updated today, worth a look"},
    {:neutral, "we run reporting through {brand}, happy to answer questions"}
  ]

  @authors %{
    reddit: ~w(u/marketing_mike u/dev_dana u/growth_gina u/throwaway8812 u/saas_sam u/anna_ops),
    youtube: ~w(@ChannelCraft @SocialSuiteReviews @DailyOpsTV @toolteardown @martech_mary),
    twitter: ~w(@lena_builds @ops_owen @brandwatchpro @cmo_carla @devrel_dan),
    instagram: ~w(@studio.north @thegrowthgram @agencylife.daily @maya.makes @brandbites)
  }

  @doc """
  Generates fixture mentions for a poll.

  The first poll (`poll_count: 0`) backfills history; later polls return
  0–2 fresh mentions.
  """
  @spec fetch(SmmMonitor.Fetchers.Fetcher.context()) :: {:ok, [map()]}
  def fetch(%{platform: platform, poll_count: 0} = context) do
    {:ok, backfill(platform, brand(context))}
  end

  def fetch(%{platform: platform} = context) do
    {:ok, generate(platform, brand(context), Enum.random([0, 1, 1, 2]))}
  end

  @doc "A few hours of back-dated mentions, so the dashboard starts populated."
  @spec backfill(atom(), String.t(), pos_integer()) :: [map()]
  def backfill(platform, brand, count \\ @backfill_count) do
    now = System.system_time(:millisecond)

    Enum.map(1..count, fn _index ->
      age = :rand.uniform(@backfill_span_ms)
      build(platform, brand, now - age)
    end)
  end

  @doc "`count` mentions timestamped in the last few seconds."
  @spec generate(atom(), String.t(), non_neg_integer()) :: [map()]
  def generate(_platform, _brand, 0), do: []

  def generate(platform, brand, count) do
    now = System.system_time(:millisecond)
    Enum.map(1..count, fn _index -> build(platform, brand, now - :rand.uniform(5_000)) end)
  end

  defp build(platform, brand, timestamp_ms) do
    {_intent, template} = Enum.random(@templates)
    author = platform |> authors() |> Enum.random()

    %{
      id: "mock-#{platform}-#{unique()}",
      platform: platform,
      author: author,
      text: String.replace(template, "{brand}", brand),
      url: url(platform),
      timestamp: timestamp_ms,
      mock: true
    }
  end

  defp authors(platform), do: Map.get(@authors, platform, ~w(@someone @someone_else))

  defp url(platform), do: "https://example.test/#{platform}/#{unique()}"

  defp brand(%{keywords: [first | _rest]}), do: first
  defp brand(_context), do: "the brand"

  defp unique, do: 6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
