defmodule Dokkit.Slots do
  @moduledoc "Which half hours a machine was heard from, so a quiet machine shows as no signal."
  import Ecto.Query
  alias Dokkit.{Machine, MachineSlot, Repo}

  @table :dokkit_slots
  @keep_days 30
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

  @doc "The same for machines named by an app, which are known by name."
  def touch_named(names, now \\ DateTime.utc_now()) do
    case fresh(names, slot(now)) do
      [] ->
        :ok

      names ->
        ids = Repo.all(from m in Machine, where: m.name in ^names, select: m.id)
        write(ids, slot(now))
    end
  end

  # One entry for each key keeps the table as small as the estate.
  defp fresh(keys, slot) do
    Enum.filter(keys, fn key ->
      case :ets.lookup(@table, key) do
        [{_, ^slot}] -> false
        _ -> :ets.insert(@table, {key, slot})
      end
    end)
  end

  defp write(ids, slot) do
    rows = for id <- ids, do: %{machine_id: id, slot: slot}
    Repo.insert_all(MachineSlot, rows, on_conflict: :nothing)
    :ok
  end

  def prune(now) do
    Repo.delete_all(
      from s in MachineSlot, where: s.slot < ^DateTime.add(now, -@keep_days * 86_400)
    )
  end
end
