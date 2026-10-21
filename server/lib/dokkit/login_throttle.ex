defmodule Dokkit.LoginThrottle do
  @moduledoc """
  Counts sign-in attempts before the password is hashed. A name and address pair, and an
  address on its own, are refused over their limit; a name on its own only slows down.
  """
  @table :dokkit_login_throttle
  @window 600

  def init, do: :ets.new(@table, [:named_table, :public, :set])

  @doc "Counts one attempt. Returns :blocked when over a limit, else :ok (after a delay if the name is being hammered)."
  def attempt(name, address) do
    prune()
    pair = hit({:pair, name, address})
    addr = hit({:address, address})
    by_name = hit({:name, name})
    v = Dokkit.Values.all()

    cond do
      pair > v["login_pair"] or addr > v["login_address"] ->
        :blocked

      by_name > v["login_name"] ->
        Process.sleep(1000)
        :ok

      true ->
        :ok
    end
  end

  @doc "Gives back an attempt that was not a wrong password."
  def refund(name, address) do
    :ets.delete(@table, {:pair, name, address})
    :ets.delete(@table, {:name, name})

    try do
      :ets.update_counter(@table, {:address, address}, {2, -1, 0, 0})
    rescue
      ArgumentError -> 0
    end
  end

  defp now, do: System.monotonic_time(:second)

  defp hit(key) do
    n = :ets.update_counter(@table, key, {2, 1}, {key, 0, now()})

    [{_, _, since}] = :ets.lookup(@table, key)

    if since < now() - @window do
      :ets.insert(@table, {key, 1, now()})
      1
    else
      n
    end
  end

  defp prune do
    if :ets.info(@table, :size) > 10_000,
      do: :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now() - @window}], [true]}])
  end
end
