defmodule Konet.HistoryTest do
  use ExUnit.Case, async: false

  alias Konet.History

  setup do
    Application.put_env(:konet, :history_limit, 3)

    on_exit(fn ->
      Application.put_env(:konet, :history_limit, 0)
      Application.delete_env(:konet, :history_ttl_seconds)
    end)

    :ok
  end

  defp settle, do: :sys.get_state(History)

  test "records and replays oldest first" do
    History.forget("hist-order")

    History.record("hist-order", "a", %{"n" => 1})
    History.record("hist-order", "b", %{"n" => 2})
    settle()

    assert [%{event: "a"}, %{event: "b"}] = History.list("hist-order")
  end

  test "keeps only the last N" do
    History.forget("hist-limit")

    for n <- 1..5, do: History.record("hist-limit", "e#{n}", %{})
    settle()

    events = History.list("hist-limit") |> Enum.map(& &1.event)
    assert events == ["e3", "e4", "e5"]
  end

  test "disabled when the limit is zero" do
    Application.put_env(:konet, :history_limit, 0)

    History.record("hist-off", "a", %{})
    settle()

    assert History.list("hist-off") == []
  end

  test "a room's buffer outlives the room emptying" do
    # The whole point: an agent broadcasts into an empty room and a client
    # arriving seconds later still sees it. Eviction must therefore be based on
    # age, never on the room having no members.
    History.forget("hist-empty")

    History.record("hist-empty", "posted-to-nobody", %{})
    settle()

    assert [%{event: "posted-to-nobody"}] = History.list("hist-empty")
  end

  test "a room's buffer is swept once it exceeds the TTL" do
    History.forget("hist-ttl")

    History.record("hist-ttl", "old", %{})
    settle()
    assert History.list("hist-ttl") != []

    # Everything already written is now older than the TTL.
    Application.put_env(:konet, :history_ttl_seconds, 0)
    send(History, :sweep)
    settle()

    assert History.list("hist-ttl") == [],
           "an untouched room must not sit in ETS until restart"
  end

  test "the sweep spares a room that is still being written to" do
    History.forget("hist-fresh")
    Application.put_env(:konet, :history_ttl_seconds, 900)

    History.record("hist-fresh", "recent", %{})
    settle()

    send(History, :sweep)
    settle()

    assert [%{event: "recent"}] = History.list("hist-fresh")
  end
end
