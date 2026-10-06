defmodule DokkitWeb.AuthTest do
  use ExUnit.Case, async: true
  alias DokkitWeb.Auth

  test "a burst of changes reloads once now and once more when the timer fires" do
    load = fn s ->
      send(self(), :loaded)
      s
    end

    for _ <- 1..5, do: Auth.debounce(%{}, :burst, load, 10)
    assert_receive :loaded
    refute_receive :loaded, 5
    assert_receive {:settled, :burst}, 500
    Auth.settle(%{}, :burst, load, 10)
    assert_receive :loaded
    assert_receive {:settled, :burst}, 500
    Auth.settle(%{}, :burst, load, 10)
    refute_receive :loaded, 50
  end
end
