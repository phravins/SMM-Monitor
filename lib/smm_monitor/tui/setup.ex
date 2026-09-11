defmodule SmmMonitor.TUI.Setup do
  @moduledoc """
  The first-run wizard: four questions, all of them skippable.

  Pure state, like the rest of the dashboard's logic — it holds answers
  and moves between steps, and knows nothing about terminals or files.
  `SmmMonitor.TUI.Model` drives it and applies the result.

  ## What it asks

  The brand to watch, then Reddit and YouTube credentials. Nothing else:
  a wizard that asks twelve questions is a wizard people quit. Twitter
  and Instagram take long enough to set up that the README is the right
  place for them, and both can be added later without coming back here.

  ## Nothing is required

  `Esc` on the first question means "just show me demo data" and lands
  straight on the summary. `Esc` on a credential skips that platform.
  Somebody should be able to get from download to dashboard without
  having an API key, because on their first run they won't have one.
  """

  defstruct step: :brand,
            answers: %{brand: "", reddit_id: "", reddit_secret: "", youtube_key: ""},
            demo: false,
            error: nil

  @type step :: :brand | :reddit_id | :reddit_secret | :youtube_key | :review | :finished
  @type t :: %__MODULE__{}

  @steps [:brand, :reddit_id, :reddit_secret, :youtube_key, :review]

  @fields %{
    brand: :brand,
    reddit_id: :reddit_id,
    reddit_secret: :reddit_secret,
    youtube_key: :youtube_key
  }

  @doc "A fresh wizard, on its first question."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The steps, in order, for the progress line."
  @spec steps() :: [step()]
  def steps, do: @steps

  @doc "Which numbered step this is, out of how many."
  @spec position(t()) :: {pos_integer(), pos_integer()}
  def position(%__MODULE__{step: :finished}), do: {length(@steps), length(@steps)}

  def position(%__MODULE__{step: step}) do
    {Enum.find_index(@steps, &(&1 == step)) + 1, length(@steps)}
  end

  @doc "Whether the wizard is done and its answers can be applied."
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{step: :finished}), do: true
  def finished?(%__MODULE__{}), do: false

  @doc "The text being typed on this step."
  @spec value(t()) :: String.t()
  def value(%__MODULE__{step: step, answers: answers}) do
    case Map.get(@fields, step) do
      nil -> ""
      field -> Map.get(answers, field, "")
    end
  end

  @doc "The brand to watch, or `nil` when they skipped it."
  @spec brand(t()) :: String.t() | nil
  def brand(%__MODULE__{demo: true}), do: nil

  def brand(%__MODULE__{answers: answers}) do
    case String.trim(answers.brand) do
      "" -> nil
      brand -> brand
    end
  end

  @doc """
  The credentials to store, leaving out the ones that were skipped.

  A half-filled Reddit app — an id with no secret — is dropped rather
  than saved: it can't authenticate, and keeping it would make the
  dashboard claim Reddit was configured when it isn't.
  """
  @spec credentials(t()) :: map()
  def credentials(%__MODULE__{answers: answers}) do
    reddit_id = String.trim(answers.reddit_id)
    reddit_secret = String.trim(answers.reddit_secret)
    youtube_key = String.trim(answers.youtube_key)

    %{}
    |> put_if(reddit_id != "" and reddit_secret != "", :reddit, %{
      client_id: reddit_id,
      client_secret: reddit_secret
    })
    |> put_if(youtube_key != "", :youtube, %{api_key: youtube_key})
  end

  @doc "Which platforms will poll for real once this is applied."
  @spec live_platforms(t()) :: [atom()]
  def live_platforms(%__MODULE__{} = setup), do: setup |> credentials() |> Map.keys() |> Enum.sort()

  @doc """
  Applies a keypress.

  Every printable character types into the current answer, which is why
  there are no single-letter shortcuts on this screen: a brand called
  "Quill" has to be typeable.
  """
  @spec handle_key(t(), {:char, char()} | {:key, atom()}) :: t()
  def handle_key(%__MODULE__{step: :finished} = setup, _key), do: setup

  def handle_key(%__MODULE__{step: :review} = setup, {:key, :enter}) do
    %{setup | step: :finished}
  end

  def handle_key(%__MODULE__{step: :review} = setup, _key), do: setup

  def handle_key(%__MODULE__{step: :brand} = setup, {:key, :escape}) do
    # "Skip, use demo data" — and skip the credentials too, since there
    # is no brand for them to search for yet.
    %{setup | demo: true, step: :review, error: nil}
  end

  def handle_key(%__MODULE__{} = setup, {:key, :escape}), do: advance(setup)

  def handle_key(%__MODULE__{step: :brand} = setup, {:key, :enter}) do
    if String.trim(setup.answers.brand) == "" do
      %{setup | error: "type a brand to watch, or press Esc to look around with demo data"}
    else
      advance(setup)
    end
  end

  def handle_key(%__MODULE__{} = setup, {:key, :enter}), do: advance(setup)

  def handle_key(%__MODULE__{} = setup, {:key, :backspace}) do
    update_answer(setup, &String.slice(&1, 0..-2//1))
  end

  def handle_key(%__MODULE__{} = setup, {:char, char}) when char >= 32 do
    update_answer(setup, &(&1 <> <<char::utf8>>))
  end

  def handle_key(%__MODULE__{} = setup, _key), do: setup

  # --- what the screen says ---------------------------------------------------

  @doc "The heading for the current step."
  @spec title(t()) :: String.t()
  def title(%__MODULE__{step: :brand}), do: "What should I watch for?"
  def title(%__MODULE__{step: :reddit_id}), do: "Reddit (optional)"
  def title(%__MODULE__{step: :reddit_secret}), do: "Reddit (optional)"
  def title(%__MODULE__{step: :youtube_key}), do: "YouTube (optional)"
  def title(%__MODULE__{}), do: "Ready"

  @doc "The label in front of the input box."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{step: :brand}), do: "brand or keyword"
  def label(%__MODULE__{step: :reddit_id}), do: "client id"
  def label(%__MODULE__{step: :reddit_secret}), do: "client secret"
  def label(%__MODULE__{step: :youtube_key}), do: "API key"
  def label(%__MODULE__{}), do: ""

  @doc "The explanation under the heading, as lines."
  @spec description(t()) :: [String.t()]
  def description(%__MODULE__{step: :brand}) do
    [
      "The name people would use when they talk about your client —",
      "a brand, a product, a handle. You can add more later, and you can",
      "watch several clients at once from the clients screen."
    ]
  end

  def description(%__MODULE__{step: :reddit_id}) do
    [
      "Reddit needs a free \"script\" app: reddit.com/prefs/apps.",
      "Skip this and Reddit shows demo data until you add it."
    ]
  end

  def description(%__MODULE__{step: :reddit_secret}) do
    ["The secret from the same app page."]
  end

  def description(%__MODULE__{step: :youtube_key}) do
    [
      "A YouTube Data API v3 key from console.cloud.google.com.",
      "Skip this and YouTube shows demo data until you add it."
    ]
  end

  def description(%__MODULE__{}), do: []

  @doc "The keys that do something on this step."
  @spec hint(t()) :: String.t()
  def hint(%__MODULE__{step: :brand}), do: "Enter to continue · Esc to skip and watch demo data"
  def hint(%__MODULE__{step: :review}), do: "Enter to open the dashboard"
  def hint(%__MODULE__{}), do: "Enter to continue · Esc to skip this one"

  @doc """
  The summary on the last step: what is about to happen, in plain words.

  This is the screen that has to make the demo/live distinction
  impossible to miss — somebody who skipped everything should not spend
  an afternoon believing invented mentions are real.
  """
  @spec summary(t()) :: [String.t()]
  def summary(%__MODULE__{} = setup) do
    watching =
      case brand(setup) do
        nil -> "Watching: the sample brand, with demo data"
        brand -> "Watching: #{brand}"
      end

    [watching | live_summary(setup)]
  end

  defp live_summary(%__MODULE__{} = setup) do
    case live_platforms(setup) do
      [] ->
        [
          "",
          "No API keys, so every mention you see will be DEMO DATA —",
          "invented, not collected. The dashboard works exactly the same;",
          "the numbers just aren't real yet.",
          "",
          "Add keys whenever you like: press c for the clients screen,",
          "then S to run this setup again."
        ]

      platforms ->
        names = Enum.map_join(platforms, " and ", &platform_name/1)

        [
          "",
          "Live: #{names} — real mentions, as they are posted.",
          "Demo data for the rest until you add their keys (press c,",
          "then S, to run this setup again)."
        ]
    end
  end

  defp platform_name(:reddit), do: "Reddit"
  defp platform_name(:youtube), do: "YouTube"
  defp platform_name(platform), do: platform |> to_string() |> String.capitalize()

  # --- internals --------------------------------------------------------------

  defp advance(%__MODULE__{step: step} = setup) do
    next =
      @steps
      |> Enum.drop_while(&(&1 != step))
      |> Enum.drop(1)
      |> List.first()

    %{setup | step: next || :review, error: nil}
  end

  defp update_answer(%__MODULE__{step: step} = setup, fun) do
    case Map.get(@fields, step) do
      nil ->
        setup

      field ->
        %{setup | answers: Map.update!(setup.answers, field, fun), error: nil}
    end
  end

  defp put_if(map, false, _key, _value), do: map
  defp put_if(map, true, key, value), do: Map.put(map, key, value)
end
