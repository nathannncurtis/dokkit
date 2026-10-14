defmodule Dokkit.Phones.Sender do
  @moduledoc "Uploads to the relay in the sweep, and soon after an issue changes: a burst of changes makes one upload."
  use GenServer
  require Logger

  @quiet 3_000
  @gap 20_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def tick, do: GenServer.cast(__MODULE__, :tick)

  def init(_) do
    Dokkit.Issues.subscribe()
    {:ok, %{timer: nil, last: nil}}
  end

  def handle_cast(:tick, state), do: {:noreply, send_now(state)}

  def handle_info(:issues_changed, %{timer: nil, last: last} = state) do
    wait = if last, do: max(@quiet, @gap - (now() - last)), else: @quiet
    {:noreply, %{state | timer: Process.send_after(self(), :upload, wait)}}
  end

  def handle_info(:issues_changed, state), do: {:noreply, state}
  def handle_info(:upload, state), do: {:noreply, send_now(%{state | timer: nil})}

  defp send_now(%{timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)

    try do
      Dokkit.Phones.upload()
    rescue
      e -> Logger.error("Phone upload failed: " <> Exception.message(e))
    end

    %{state | timer: nil, last: now()}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
