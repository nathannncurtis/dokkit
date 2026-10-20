defmodule Dokkit.Demo do
  @moduledoc """
  The public demo: seats, the line for them, and the sample company rebuilt on the hour.
  Open pages hear `{:demo, {:warn, seconds, spot}}`, `{:demo, :back}`, `{:demo, {:away, reason}}`
  and `{:demo, :reload}`.
  """
  use GenServer
  alias Dokkit.Demo.{Sample, Seats}

  @tick 5_000

  def on?, do: Application.get_env(:dokkit, :demo, false)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def take(address), do: GenServer.call(__MODULE__, {:take, address})
  def poll(ticket), do: GenServer.call(__MODULE__, {:poll, ticket})
  def claim(ticket), do: GenServer.call(__MODULE__, {:claim, ticket})
  def attach(seat, pid), do: GenServer.call(__MODULE__, {:attach, seat, pid})
  def act(seat, action), do: GenServer.cast(__MODULE__, {:act, seat, action})
  def here(seat), do: GenServer.call(__MODULE__, {:here, seat})
  def leave(seat), do: GenServer.cast(__MODULE__, {:leave, seat})
  def seated?(seat), do: GenServer.call(__MODULE__, {:seated?, seat})
  def stats, do: GenServer.call(__MODULE__, :stats)
  def tick, do: send(__MODULE__, :tick)

  @impl true
  def init(opts) do
    unless opts[:build] == false, do: Sample.reset()
    Process.send_after(self(), :tick, @tick)
    unless opts[:reset] == false, do: next_reset()
    {:ok, Seats.new(Application.get_env(:dokkit, :demo_limits, %{}))}
  end

  @impl true
  def handle_call({:take, address}, _, s), do: reply(Seats.take(s, address, now()))
  def handle_call({:poll, ticket}, _, s), do: reply(Seats.poll(s, ticket, now()))
  def handle_call({:claim, ticket}, _, s), do: reply(Seats.claim(s, ticket, now()))
  def handle_call({:seated?, seat}, _, s), do: {:reply, Seats.seated?(s, seat), s}
  def handle_call(:stats, _, s), do: {:reply, Seats.stats(s), s}

  def handle_call({:attach, seat, pid}, _, s) do
    {answer, s} = Seats.attach(s, seat, pid)
    if answer == :ok, do: Process.monitor(pid)
    {:reply, answer, s}
  end

  def handle_call({:here, seat}, _, s) do
    {answer, s} = Seats.here(s, seat, now())
    if answer == :ok, do: tell(pids(s, seat), :back)
    {:reply, answer, s}
  end

  @impl true
  def handle_cast({:act, seat, action}, s) do
    warned = Seats.warned?(s, seat)
    s = Seats.act(s, seat, action, now())
    if warned and not Seats.warned?(s, seat), do: tell(pids(s, seat), :back)
    {:noreply, s}
  end

  def handle_cast({:leave, seat}, s), do: {:noreply, Seats.leave(s, seat, now())}

  @impl true
  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, @tick)
    {events, s} = Seats.tick(s, now())

    for event <- events do
      case event do
        {:warn, pids, ends, spot} -> tell(pids, {:warn, max(div(ends - now(), 1000), 0), spot})
        {:away, pids, reason} -> tell(pids, {:away, reason})
      end
    end

    {:noreply, s}
  end

  def handle_info(:reset, s) do
    next_reset()
    Sample.reset()
    tell(Enum.flat_map(s.seats, fn {_, seat} -> MapSet.to_list(seat.pids) end), :reload)
    {:noreply, s}
  end

  def handle_info({:DOWN, _, :process, pid, _}, s), do: {:noreply, Seats.detach(s, pid, now())}

  def minutes_to_reset, do: 60 - DateTime.utc_now().minute

  defp next_reset do
    t = DateTime.utc_now()
    Process.send_after(self(), :reset, ((59 - t.minute) * 60 + 60 - t.second) * 1000)
  end

  defp pids(s, seat), do: if(x = s.seats[seat], do: MapSet.to_list(x.pids), else: [])
  defp tell(pids, message), do: Enum.each(pids, &send(&1, {:demo, message}))
  defp reply({answer, s}), do: {:reply, answer, s}
  defp now, do: System.monotonic_time(:millisecond)
end
