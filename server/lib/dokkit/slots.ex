defmodule Dokkit.Slots do
  @moduledoc "Which half hours a machine was heard from, so a quiet machine shows as no signal."
  import Ecto.Query
  alias Dokkit.{Machine, MachineSlot, Repo}

  @table :dokkit_slots
  @step 1800

  def init, do: :ets.new(@table, [:named_table, :public, :set])

  def step, do: @step

  @doc "The start of the half hour that holds `time`."
  def slot(%DateTime{} = time) do
    s = DateTime.to_unix(time)
    DateTime.from_unix!(s - Integer.mod(s, @step))
  end

  @doc "Notes that machines (by id) were heard from. Writes only the first time in each half hour."
  def touch(ids, now \\ DateTime.utc_now()) do
    case fresh(List.wrap(ids), slot(now)) do
      [] -> :ok
      ids -> write(ids, slot(now))
    end
  end

  @doc "The same for machines an app names. Only a machine that was seen, never an enrolled one, is marked by its name."
  def touch_named(names, now \\ DateTime.utc_now()) do
    ids = Repo.all(from m in Machine, where: m.name in ^names and m.kind == :seen, select: m.id)
    touch(ids, now)
  end

  # One entry for each machine id keeps the table as small as the estate. An id is marked after its row is written.
  defp fresh(ids, slot) do
    unix = DateTime.to_unix(slot)
    Enum.reject(ids, &match?([{_, ^unix}], :ets.lookup(@table, &1)))
  end

  defp write(ids, slot) do
    rows = for id <- ids, do: %{machine_id: id, slot: slot}
    Repo.insert_all(MachineSlot, rows, on_conflict: :nothing)
    for id <- ids, do: :ets.insert(@table, {id, DateTime.to_unix(slot)})
    :ok
  end

  def prune(now) do
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", DateTime.to_unix(slot(now))}], [true]}])

    Repo.delete_all(
      from s in MachineSlot,
        where: s.slot < ^DateTime.add(now, -Dokkit.Values.get("slots_days") * 86_400)
    )
  end
end
