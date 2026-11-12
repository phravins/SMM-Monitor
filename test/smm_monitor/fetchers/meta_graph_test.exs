defmodule SmmMonitor.Fetchers.MetaGraphTest do
  use ExUnit.Case, async: true

  alias SmmMonitor.Fetchers.MetaGraph

  doctest MetaGraph

  defp body(error), do: %{"error" => error}

  test "190 and the expired-session subcodes are an expired token" do
    assert {:expired_token, "gone"} =
             MetaGraph.classify(body(%{"code" => 190, "message" => "gone"}))

    assert {:expired_token, _} = MetaGraph.classify(body(%{"code" => 102, "error_subcode" => 463}))
    assert {:expired_token, _} = MetaGraph.classify(body(%{"code" => 102, "error_subcode" => 467}))
  end

  test "throttling codes carry Meta's stated wait" do
    for code <- [4, 17, 32, 613] do
      error = %{
        "code" => code,
        "message" => "slow down",
        "error_data" => %{"estimated_time_to_regain_access" => 12}
      }

      assert {{:throttled, 12}, "slow down"} = MetaGraph.classify(body(error))
    end
  end

  test "throttling with no stated wait has none" do
    assert {{:throttled, nil}, _} = MetaGraph.classify(body(%{"code" => 4}))

    assert {{:throttled, nil}, _} =
             MetaGraph.classify(
               body(%{"code" => 4, "error_data" => %{"estimated_time_to_regain_access" => 0}})
             )
  end

  test "10 and 200-299 are a missing permission" do
    for code <- [10, 200, 250, 299] do
      assert {:missing_permission, _} = MetaGraph.classify(body(%{"code" => code}))
    end
  end

  test "anything else is other, with the message if there is one" do
    assert {:other, "bad param"} =
             MetaGraph.classify(body(%{"code" => 100, "message" => "bad param"}))

    assert {:other, nil} = MetaGraph.classify(%{})
    assert {:other, nil} = MetaGraph.classify("<html>")
    assert {:other, nil} = MetaGraph.classify(nil)
  end
end
