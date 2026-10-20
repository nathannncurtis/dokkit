defmodule Dokkit.Demo.SeatsTest do
  use ExUnit.Case, async: true
  alias Dokkit.Demo.Seats

  @min 60_000

  defp seated(limits \\ %{}) do
    {{:seat, id}, s} = Seats.take(Seats.new(limits), {1, 1, 1, 1}, 0)
    {:ok, s} = Seats.attach(s, id, self())
    {s, id}
  end

  defp away?(events), do: Enum.any?(events, &match?({:away, _, _}, &1))

  test "a seat when one is free, a place in line when not, three per address" do
    s = Seats.new(%{seats: 2})
    {{:seat, _}, s} = Seats.take(s, {1, 1, 1, 1}, 0)
    {{:seat, _}, s} = Seats.take(s, {2, 2, 2, 2}, 0)
    {{:line, a}, s} = Seats.take(s, {3, 3, 3, 3}, 0)
    {{:line, b}, s} = Seats.take(s, {4, 4, 4, 4}, 0)
    assert {{:waiting, 1}, s} = Seats.poll(s, a, 1000)
    assert {{:waiting, 2}, s} = Seats.poll(s, b, 1000)
    {{:line, _}, s} = Seats.take(s, {1, 1, 1, 1}, 0)
    {{:line, _}, s} = Seats.take(s, {1, 1, 1, 1}, 0)
    assert {:address_limit, _} = Seats.take(s, {1, 1, 1, 1}, 0)
  end

  test "moving the mouse never reaches here; only different actions keep the seat" do
    {s, id} = seated()
    s = Enum.reduce(1..20, s, &Seats.act(&2, id, {"click", %{"x" => 1}}, &1 * 20_000))
    {events, s} = Seats.tick(s, 5 * @min + 20_000)
    assert [{:warn, _, ends, {_, _}}] = events
    assert ends == 6 * @min + 20_000
    {events, _} = Seats.tick(s, 6 * @min + 20_000)
    assert away?(events)
  end

  test "a new page or control renews; one of the last three does not" do
    {s, id} = seated()
    s = Seats.act(s, id, {:page, "/all"}, 4 * @min)
    s = Seats.act(s, id, {:page, "/logs"}, 8 * @min)
    s = Seats.act(s, id, {:page, "/all"}, 12 * @min)
    {events, s} = Seats.tick(s, 12 * @min + 30_000)
    refute away?(events)
    s = Seats.act(s, id, {:page, "/jobs"}, 13 * @min)
    {events, _} = Seats.tick(s, 14 * @min)
    assert events == []
  end

  test "Still there? keeps the seat twice in a row, then only a real action does" do
    {s, id} = seated()
    {_, s} = Seats.tick(s, 5 * @min)
    {:ok, s} = Seats.here(s, id, 5 * @min)
    {_, s} = Seats.tick(s, 10 * @min)
    {:ok, s} = Seats.here(s, id, 10 * @min)
    {_, s} = Seats.tick(s, 15 * @min)
    assert {:no, s} = Seats.here(s, id, 15 * @min)
    {events, _} = Seats.tick(s, 16 * @min)
    assert away?(events)
  end

  test "the warning moves each time it shows" do
    spots =
      for _ <- 1..20 do
        {s, _} = seated()
        {[{:warn, _, _, spot}], _} = Seats.tick(s, 5 * @min)
        spot
      end

    assert length(Enum.uniq(spots)) > 1
  end

  test "a seat with no open page goes after two minutes" do
    {s, id} = seated()
    s = Seats.detach(s, self(), 0)
    {events, s} = Seats.tick(s, @min)
    assert events == []
    {[{:away, _, :gone}], s} = Seats.tick(s, 2 * @min)
    refute Seats.seated?(s, id)
  end

  test "a freed seat is offered to the head of the line and held two minutes" do
    {s, id} = seated(%{seats: 1})
    {{:line, t}, s} = Seats.take(s, {9, 9, 9, 9}, 0)
    s = Seats.leave(s, id, 1000)
    assert {{:turn, 121_000}, s} = Seats.poll(s, t, 1000)
    assert {{:seat, _}, s} = Seats.claim(s, t, 2000)
    assert Seats.stats(s) == %{taken: 1, seats: 1, freed: 1}
  end

  test "an unclaimed turn and a closed waiting tab both leave the line" do
    {s, id} = seated(%{seats: 1})
    {{:line, t}, s} = Seats.take(s, {9, 9, 9, 9}, 0)
    {{:line, u}, s} = Seats.take(s, {8, 8, 8, 8}, 0)
    s = Seats.leave(s, id, 1000)
    {_, s} = Seats.poll(s, u, 100_000)
    {_, s} = Seats.tick(s, 125_000)
    assert {:gone, s} = Seats.poll(s, t, 125_000)
    assert {{:turn, _}, s} = Seats.poll(s, u, 125_000)
    {_, s} = Seats.tick(s, 200_000)
    assert {:gone, _} = Seats.poll(s, u, 200_000)
  end

  test "while someone waits, seats held over twenty minutes end first, even busy ones" do
    {s, id} = seated(%{seats: 1})
    s = Enum.reduce(1..25, s, &Seats.act(&2, id, {:page, "/#{&1}"}, &1 * @min))
    {events, _} = Seats.tick(s, 25 * @min)
    refute away?(events)
    {{:line, t}, s} = Seats.take(s, {9, 9, 9, 9}, 25 * @min)
    {_, s} = Seats.poll(s, t, 25 * @min)
    {[{:away, _, :long}], s} = Seats.tick(s, 25 * @min)
    assert {{:turn, _}, _} = Seats.poll(s, t, 25 * @min)
  end
end
