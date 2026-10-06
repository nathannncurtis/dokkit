defmodule Dokkit.LoginThrottle do
  @moduledoc "Counts failed sign-ins per name and per address, so guessing cannot run unchecked."
  @table :dokkit_login_throttle
  @window 600
  @per_name 10
  @per_address 30

  def init, do: :ets.new(@table, [:named_table, :public, :set])

  def blocked?(name, address),
    do: count({:name, name}) >= @per_name or count({:address, address}) >= @per_address

  def failed(name, address) do
    prune()
    bump({:name, name})
    bump({:address, address})
  end

  def cleared(name), do: :ets.delete(@table, {:name, name})

  defp now, do: System.monotonic_time(:second)

  defp count(key) do
    case :ets.lookup(@table, key) do
      [{_, n, since}] -> if now() - since < @window, do: n, else: 0
      _ -> 0
    end
  end

  defp bump(key) do
    case :ets.lookup(@table, key) do
      [{_, n, since}] when n > 0 ->
        if now() - since < @window,
          do: :ets.insert(@table, {key, n + 1, since}),
          else: :ets.insert(@table, {key, 1, now()})

      _ ->
        :ets.insert(@table, {key, 1, now()})
    end
  end

  defp prune do
    if :ets.info(@table, :size) > 10_000,
      do: :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now() - @window}], [true]}])
  end
end
