defmodule Dokkit.RateLimit do
  @moduledoc "A token bucket per key, held in memory. Lines are the unit."
  @capacity 10_000
  @per_second 100

  def child_spec(_) do
    start = {Agent, :start_link, [fn -> :ets.new(__MODULE__, [:named_table, :public]) end]}
    %{id: __MODULE__, start: start}
  end

  @doc "Takes `cost` from the key's bucket. `:ok`, or `{:wait, seconds}` until it would fit."
  def take(id, cost, now \\ System.monotonic_time(:millisecond)) do
    {tokens, at} =
      case :ets.lookup(__MODULE__, id) do
        [{_, tokens, at}] -> {tokens, at}
        [] -> {@capacity, now}
      end

    tokens = min(@capacity, tokens + (now - at) * @per_second / 1000)
    cost = min(cost, @capacity)

    # ponytail: read then write, so two simultaneous requests can both pass; a lock if that matters
    if tokens >= cost do
      :ets.insert(__MODULE__, {id, tokens - cost, now})
      :ok
    else
      :ets.insert(__MODULE__, {id, tokens, now})
      {:wait, ceil((cost - tokens) / @per_second)}
    end
  end
end
