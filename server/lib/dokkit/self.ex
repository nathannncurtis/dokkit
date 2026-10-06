defmodule Dokkit.Self do
  @moduledoc """
  Dokkit watching itself. It calls an outside address each minute, so something else can
  notice when the calls stop, and it keeps a row for itself like any other service.
  """
  alias Dokkit.{Check, Issues, Machine, Repo, Service}

  def tick(now, config) do
    url = config["heartbeat_url"]
    if url not in [nil, ""], do: beat(url)
    row(now)
  end

  defp beat(url) do
    Req.get(
      url,
      [retry: false, receive_timeout: 10_000] ++ Application.get_env(:dokkit, :req_options, [])
    )
  rescue
    _ -> nil
  end

  # The database answering and its size. A full disk shows here before it stops intake.
  defp row(now) do
    machine =
      Repo.get_by(Machine, name: "Dokkit") || Repo.insert!(%Machine{name: "Dokkit", kind: :group})

    service =
      Repo.get_by(Service, machine_id: machine.id, slug: "dokkit") ||
        Repo.insert!(%Service{
          machine_id: machine.id,
          slug: "dokkit",
          name: "Dokkit",
          version: to_string(Application.spec(:dokkit, :vsn)),
          route_down: "push",
          route_degraded: "push"
        })

    check =
      Repo.get_by(Check, service_id: service.id, name: "database") ||
        Repo.insert!(%Check{
          service_id: service.id,
          name: "database",
          type: :custom,
          fail_after: 1
        })

    case Repo.query("SELECT pg_database_size(current_database())") do
      {:ok, %{rows: [[bytes]]}} ->
        mb = bytes / 1_048_576
        Dokkit.Numbers.record(machine.id, service, "database.size_mb", mb, now)
        Issues.record(check, :ok, at: now, value: mb)

      _ ->
        Issues.record(check, :down, at: now, note: "The database did not answer.")
    end
  end
end
