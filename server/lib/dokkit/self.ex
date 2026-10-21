defmodule Dokkit.Self do
  @moduledoc """
  Dokkit watching itself. Its row pages when it stops taking reports or cannot reach its database, and pushes for lesser trouble; the two channels are settings on the Alerts page. It calls an outside address each minute, so something else can
  notice when the calls stop, and it keeps a row for itself like any other service.
  """
  import Ecto.Query, only: [from: 2]
  require Logger
  alias Dokkit.{Check, Issues, Machine, Repo, Service}

  @failed {__MODULE__, :database_failed}
  @down_after 3

  def tick(now, config, booted \\ nil) do
    url = config["heartbeat_url"]
    size = Application.get_env(:dokkit, :database_probe, &database_size/0).()
    # A database that does not answer cannot record it, so the outside call stops instead.
    if url not in [nil, ""] and match?({:ok, _}, size), do: beat(url)
    row(now, booted, config, size)
  end

  @doc """
  The database's size in bytes, asked over a connection of its own, so a busy or stuck pool is
  not mistaken for a database that does not answer.
  """
  def database_size do
    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        try do
          opts =
            Repo.config()
            |> Keyword.delete(:pool)
            |> Keyword.merge(pool_size: 1, sync_connect: true, backoff_type: :stop)

          with {:ok, pid} <- Postgrex.start_link(opts) do
            result = Postgrex.query(pid, "SELECT pg_database_size(current_database())", [])
            GenServer.stop(pid)
            result
          end
        rescue
          e -> {:error, e}
        end
      end)

    case Task.yield(task, 20_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{rows: [[bytes]]}}} -> {:ok, bytes}
      _ -> :error
    end
  end

  defp beat(url) do
    case Dokkit.Alerts.check_url(url) do
      :ok ->
        Req.get(
          url,
          [retry: false, redirect: false, receive_timeout: 10_000] ++
            Application.get_env(:dokkit, :req_options, [])
        )

      {:error, why} ->
        Logger.warning("The heartbeat was not sent: #{why}")
    end
  rescue
    _ -> nil
  end

  # The database answering and its size. A full disk shows here before it stops intake.
  defp row(now, booted, config, size) do
    machine =
      Repo.get_by(Machine, name: "Dokkit") || Repo.insert!(%Machine{name: "Dokkit", kind: :group})

    {down, degraded} = Dokkit.Alerts.self_routes(config)

    service =
      Repo.get_by(Service, machine_id: machine.id, slug: "dokkit") ||
        Repo.insert!(%Service{
          machine_id: machine.id,
          slug: "dokkit",
          name: "Dokkit",
          version: to_string(Application.spec(:dokkit, :vsn))
        })

    service =
      if {service.route_down, service.route_degraded} == {down, degraded},
        do: service,
        else:
          Repo.update!(Ecto.Changeset.change(service, route_down: down, route_degraded: degraded))

    case size do
      {:ok, bytes} ->
        :persistent_term.put(@failed, 0)
        mb = bytes / 1_048_576
        Dokkit.Numbers.record(machine.id, service, "database.size_mb", mb, now)
        Issues.record(check(service, "database"), :ok, at: now, value: mb)

      _ ->
        failed = :persistent_term.get(@failed, 0) + 1
        :persistent_term.put(@failed, failed)

        # A stall of a few seconds while the disk catches up is not an outage.
        if failed >= @down_after,
          do:
            Issues.record(check(service, "database"), :down,
              at: now,
              note: "The database has not answered for #{failed} minutes."
            )
    end

    reports(service, now, booted)
    certificate(service, now)
    archive(service, now)
    relay(service, now)
  end

  defp certificate(service, now) do
    failed =
      case Dokkit.Acme.renewal() do
        %{ok: false, note: note} -> " " <> note
        _ -> ""
      end

    warn = Dokkit.Values.get("cert_warn_days")

    case Dokkit.Certificate.days_left(now) do
      nil ->
        nil

      days when days <= 0 ->
        Issues.record(check(service, "certificate"), :down,
          at: now,
          value: days,
          note: "The uploaded certificate has run out." <> failed
        )

      days when days <= warn ->
        Issues.record(check(service, "certificate"), :degraded,
          at: now,
          value: days,
          soon: true,
          note: "The uploaded certificate runs out in #{trunc(days)} days." <> failed
        )

      days ->
        Issues.record(check(service, "certificate"), :ok,
          at: now,
          value: days,
          note: String.trim(failed)
        )
    end
  end

  # One quiet machine is that machine's news. Every machine quiet at once is more likely Dokkit's.
  defp reports(service, now, booted) do
    newest = Repo.one(from m in Machine, where: m.kind == :enrolled, select: max(m.last_seen_at))
    newest = if newest && booted, do: Enum.max([newest, booted], DateTime), else: newest
    quiet = newest && DateTime.diff(now, newest, :minute) * 1.0

    if quiet && quiet >= Dokkit.Values.get("self_quiet_minutes"),
      do:
        Issues.record(check(service, "reports"), :down,
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
          Issues.record(check(service, "archive"), :degraded,
            at: now,
            note: "The archive folder cannot be written to."
          )
      end
    end
  end

  defp relay(service, now) do
    case Dokkit.Phones.trouble(now) do
      nil ->
        if Repo.get_by(Check, service_id: service.id, name: "relay"),
          do: Issues.record(check(service, "relay"), :ok, at: now)

      note ->
        Issues.record(check(service, "relay"), :degraded, at: now, note: note)
    end
  end

  defp check(service, name) do
    Repo.get_by(Check, service_id: service.id, name: name) ||
      Repo.insert!(%Check{service_id: service.id, name: name, type: :custom, fail_after: 1})
  end
end
