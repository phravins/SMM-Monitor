defmodule SmmMonitor.Fetchers.Instagram do
  @moduledoc """
  Instagram fetcher — **stubbed**.

  Instagram has no public search API. Mentions require the Graph API's
  `/{ig-user-id}/mentions` edge, which needs a Business or Creator account,
  a linked Facebook Page and an app review — and it only surfaces mentions
  *of your own account*, not arbitrary brand terms. That is a client
  onboarding problem as much as a code one, so this ships mock-only.

  To finish it:

    1. set `INSTAGRAM_ACCESS_TOKEN` and `INSTAGRAM_USER_ID` for the client's
       business account,
    2. make `ready?/1` check for both,
    3. implement `fetch/1` against
       `https://graph.facebook.com/v21.0/{user_id}/tags` (posts the account
       is tagged in) and/or the `mentioned_comment` edge,
    4. map the payload with `parse/1` below.

  Note that per-client credentials will eventually need to move out of
  global config into per-client state — worth designing before wiring this
  up for more than one brand.
  """

  use SmmMonitor.Fetchers.Fetcher, platform: :instagram, display_name: "Instagram"

  @impl true
  def ready?(_context), do: false

  @impl true
  def fetch(_context, state), do: {:error, :requires_business_account_and_app_review, state}

  @doc "Maps a Graph API `/tags` payload onto mention attrs."
  @spec parse(map()) :: [map()]
  def parse(%{"data" => posts}) when is_list(posts) do
    Enum.map(posts, fn post ->
      %{
        id: "instagram-#{post["id"]}",
        platform: :instagram,
        author: "@" <> (post["username"] || "unknown"),
        text: post["caption"] || "",
        url: post["permalink"],
        timestamp: post["timestamp"]
      }
    end)
  end

  def parse(_body), do: []
end
