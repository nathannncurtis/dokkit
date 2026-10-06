defmodule Dokkit.Self do
  @moduledoc """
  Dokkit watching itself. It calls an outside address each minute, so something else can
  notice when the calls stop, and it keeps a row for itself like any other service.
  """
  import Ecto.Query, only: [from: 2]
  alias Dokkit.{Check, Issues, Machine, Repo, Service}

  def tick(now, config, booted \\ nil) do
    url = config["heartbeat_url"]
    # A database that does not answer cannot record it, so the outside call stops instead.
    if url not in [nil, ""] and match?({:ok, _}, Repo.query("SELECT 1")), do: beat(url)
    row(now, booted)
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
  defp row(now, booted) do
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

    case Repo.query("SELECT pg_database_size(current_database())") do
      {:ok, %{rows: [[bytes]]}} ->
        mb = bytes / 1_048_576
        Dokkit.Numbers.record(machine.id, service, "database.size_mb", mb, now)
        Issues.record(check(service, "database"), :ok, at: now, value: mb)

      _ ->
        Issues.record(check(service, "database"), :down,
          at: now,
          note: "The database did not answer."
        )
    end

    reports(service, now, booted)
    archive(service, now)
  end

  @quiet_minutes 10

  # One quiet machine is that machine's news. Every machine quiet at once is more likely Dokkit's.
  defp reports(service, now, booted) do
    newest = Repo.one(from m in Machine, where: m.kind == :enrolled, select: max(m.last_seen_at))
    newest = if newest && booted, do: Enum.max([newest, booted], DateTime), else: newest
    quiet = newest && DateTime.diff(now, newest, :minute) * 1.0

    if quiet && quiet >= @quiet_minutes,
      do:
        Issues.record(check(service, "reports"), :degraded,
          at: now,
          value: quiet,
          note: "No machine has reported for #{round(quiet)} minutes."
        ),
      else: Issues.record(check(service, "reports"), :ok, at: now, value: quiet)
  end

  defp archive(service, now) do
    with dir when is_binary(dir) <- Application.get_env(:dokkit, :archive) do
      File.mkdir_p(dir)

      # Writing is the test: file attributes say nothing of Windows permissions.
      case File.write(Path.join(dir, ".dokkit-write-check"), "") do
        :ok ->
          Issues.record(check(service, "archive"), :ok, at: now)

        {:error, _} ->
          Issues.record(check(service, "archive"), :down,
            at: now,
            note: "The archive folder cannot be written to."
          )
      end
    end
  end

  defp check(service, name) do
    Repo.get_by(Check, service_id: service.id, name: name) ||
      Repo.insert!(%Check{service_id: service.id, name: name, type: :custom, fail_after: 1})
  end
end
