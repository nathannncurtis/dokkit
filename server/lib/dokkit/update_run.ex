defmodule Dokkit.UpdateRun do
  @moduledoc "The update in progress, read from the machines' own rows so it survives a restart of the server."
  import Ecto.Query
  alias Dokkit.{Machine, Repo}

  @doc "The running update, or nil: its version, a line for each machine, and how many have finished."
  def current(now \\ DateTime.utc_now()) do
    rows = rows(now)

    case Enum.filter(rows, &(&1.state in [:waiting, :installing])) do
      [] ->
        nil

      pending ->
        since = pending |> Enum.map(& &1.started_at) |> Enum.min(DateTime)
        run = Enum.filter(rows, &(DateTime.compare(&1.started_at, since) != :lt))
        version = run |> Enum.max_by(& &1.started_at, DateTime) |> Map.fetch!(:version)
        done = Enum.count(run, &(&1.state in [:done, :failed]))
        %{version: version, machines: run, done: done, total: length(run)}
    end
  end

  @doc "Machines whose update failed or never reported, until dismissed."
  def failed(now \\ DateTime.utc_now()), do: Enum.filter(rows(now), &(&1.state == :failed))

  @doc "Forgets the finished updates that failed, so their notice goes."
  def dismiss(now \\ DateTime.utc_now()) do
    ids = for r <- failed(now), do: r.id
    Repo.update_all(from(m in Machine, where: m.id in ^ids), set: [update_started_at: nil])
    Dokkit.Issues.changed(false)
  end

  def status(%Machine{} = m, now) do
    late = Dokkit.Values.get("update_run_minutes")

    cond do
      m.update_ok == false ->
        {:failed, m.update_note || "The updater gave no reason."}

      is_nil(m.wanted_version) and m.update_ok == true ->
        {:done, nil}

      current?(m) ->
        {:done, nil}

      DateTime.diff(now, m.update_started_at) >= late * 60 ->
        {:failed, "did not report back within #{late} minutes"}

      m.update_asked_at ->
        {:installing, nil}

      true ->
        {:waiting, nil}
    end
  end

  defp rows(now) do
    for m <- Repo.all(from m in Machine, where: not is_nil(m.update_started_at), order_by: m.name) do
      {state, note} = status(m, now)

      %{
        id: m.id,
        name: m.name,
        state: state,
        note: note,
        version: m.wanted_version || m.update_version,
        started_at: m.update_started_at
      }
    end
  end

  defp current?(m) do
    parts =
      Enum.reject(
        [
          m.program_version,
          m.updater_version | if(m.hosts_server, do: [m.server_version], else: [])
        ],
        &is_nil/1
      )

    parts != [] and Enum.all?(parts, &(&1 == m.wanted_version))
  end
end
