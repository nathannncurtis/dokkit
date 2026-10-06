defmodule Dokkit.Intake do
  @moduledoc "Everything that arrives from machines and apps. See spec/api.md, Intake."
  import Ecto.Query
  alias Dokkit.{Batch, Check, Issues, JobRun, Key, Machine, Repo, Service}

  @max_lines 10_000
  @tail_bytes 16 * 1024
  @states %{"ok" => :ok, "degraded" => :degraded, "down" => :down}
  @events ~w(start progress ok fail)

  def report(%Key{} = key, batch_id, body) do
    lines = String.split(body, "\n", trim: true)
    stored = batch_id && Repo.get_by(Batch, id: batch_id, key_id: key.id)

    cond do
      length(lines) > @max_lines ->
        {:error, :too_large}

      stored ->
        {:ok, answer(stored)}

      true ->
        now = DateTime.utc_now()
        lines = Enum.map(lines, &Jason.decode/1)
        # A month's partition is made before the transaction, never inside it.
        Enum.each(lines, fn
          {:ok, %{"type" => "log"} = line} -> Dokkit.Logs.ensure_partition(line, now)
          _ -> nil
        end)

        Repo.transaction(fn -> store(key, batch_id, lines, now) end)
    end
    |> tap(fn _ -> Issues.changed() end)
  end

  @doc "Trades a one-use enrolment token for a machine and its key."
  def enrol(token, params) do
    name = String.trim(to_string(params["hostname"] || ""))

    with true <- name != "",
         {:ok, %Key{used_at: nil} = enrol} <- Dokkit.Keys.verify(token, :enrol) do
      Repo.transaction(fn ->
        now = DateTime.utc_now()
        Repo.update!(Ecto.Changeset.change(enrol, used_at: now, revoked_at: now))

        attrs = [
          kind: :enrolled,
          os: params["os"],
          arch: params["arch"],
          program_version: params["dokkit"],
          last_seen_at: now
        ]

        machine =
          case Repo.get_by(Machine, name: name) do
            nil -> Repo.insert!(struct!(Machine, [name: name] ++ attrs))
            machine -> Repo.update!(Ecto.Changeset.change(machine, attrs))
          end

        {key, _} = Dokkit.Keys.mint(:machine, %{machine_id: machine.id, label: name})
        %{machine: machine.id, key: key}
      end)
    else
      _ -> :error
    end
  end

  def ping(%Key{kind: :app} = key, name, event, run, tail) when event in @events do
    Repo.transaction(fn ->
      service = seen(key)

      job(
        service,
        %{"name" => name, "event" => event, "run" => run, "tail" => tail},
        DateTime.utc_now()
      )
    end)
    |> elem(1)
    |> tap(fn _ -> Issues.changed() end)
  end

  defp store(key, batch_id, lines, now) do
    seen(key)

    results =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {decoded, n} ->
        with {:ok, %{"type" => type} = line} <- decoded,
             ok when ok == :ok or elem(ok, 0) == :log <- line(key, type, line, at(line, now)) do
          ok
        else
          {:error, code, message} ->
            %{"line" => n, "code" => code, "message" => message}

          _ ->
            %{"line" => n, "code" => "bad_line", "message" => "Not a JSON object with a type."}
        end
      end)

    Dokkit.Logs.insert(for {:log, row} <- results, do: row)
    refused = Enum.filter(results, &is_map/1)

    batch = %Batch{
      id: batch_id,
      key_id: key.id,
      accepted: length(lines) - length(refused),
      refused: refused
    }

    if batch_id, do: Repo.insert!(batch)
    answer(batch)
  end

  defp answer(batch), do: %{accepted: batch.accepted, refused: batch.refused}

  defp line(%Key{kind: :app}, type, _, _) when type in ~w(state inventory),
    do: {:error, "not_allowed", "An app key may not send #{type}."}

  defp line(key, type, line, at) when type in ~w(state custom) do
    with {:ok, service} <- service(key, line),
         {:ok, state} <- Map.fetch(@states, line["state"]),
         name when is_binary(name) <- line["check"] do
      check = check(service, name, :custom, 3)
      Issues.record(check, state, at: at, note: line["note"], value: number(line["value"]))
      :ok
    else
      {:error, _, _} = refusal -> refusal
      _ -> {:error, "bad_line", "Needs check and a state of ok, degraded or down."}
    end
  end

  defp line(key, "beat", line, at) do
    with {:ok, service} <- service(key, line), name when is_binary(name) <- line["name"] do
      every = line["every_seconds"]
      config = %{"every_seconds" => if(is_integer(every) and every > 0, do: every, else: 60)}
      check = check(service, name, :beat, 1)

      check =
        if check.config == config,
          do: check,
          else: Repo.update!(Ecto.Changeset.change(check, config: config))

      Issues.record(check, :ok, at: at)
      :ok
    else
      {:error, _, _} = refusal -> refusal
      _ -> {:error, "bad_line", "A beat needs a name."}
    end
  end

  defp line(key, "job", line, at) do
    with {:ok, service} <- service(key, line), true <- line["event"] in @events do
      job(service, line, at)
    else
      {:error, _, _} = refusal -> refusal
      _ -> {:error, "bad_line", "Needs an event of start, progress, ok or fail."}
    end
  end

  defp line(key, "log", line, at) do
    with {:ok, service} <- log_service(key, line),
         {:ok, row} <- Dokkit.Logs.row(line, machine(key, service), service && service.id, at) do
      {:log, row}
    else
      {:error, _, _} = refusal -> refusal
      _ -> {:error, "bad_line", "A log line needs msg."}
    end
  end

  defp line(%Key{kind: :machine, machine_id: id}, "inventory", line, _at) do
    change =
      for {field, key} <- [os: "os", arch: "arch", program_version: "dokkit"],
          is_binary(line[key]),
          do: {field, line[key]}

    Repo.update_all(from(m in Machine, where: m.id == ^id), set: [kind: :enrolled] ++ change)
    :ok
  end

  # The other types are added with the features that read them.
  defp line(_, type, _, _) when type in ~w(metric stats deploy),
    do: {:error, "not_yet", "This server does not store #{type} lines yet."}

  defp line(_, type, _, _), do: {:error, "unknown_type", "Unknown type #{inspect(type)}."}

  defp job(service, line, at) do
    name = line["name"] || service.slug
    check = check(service, name, :job, 1)
    event = line["event"]
    run = find_run(check, line["run"], event)

    changes =
      %{
        "start" => [result: :running, started_at: at],
        "progress" => [],
        "ok" => [result: :ok, finished_at: at],
        "fail" => [result: :fail, finished_at: at]
      }[event]
      |> Keyword.merge(
        for {k, v} <- [
              exit_code: line["exit_code"],
              duration_ms: line["duration_ms"],
              done: line["done"],
              total: line["total"]
            ],
            is_integer(v),
            do: {k, v}
      )
      |> Keyword.merge(
        if is_binary(line["tail"]) and line["tail"] != "",
          do: [tail: tail(line["tail"])],
          else: []
      )

    run = Repo.insert_or_update!(Ecto.Changeset.change(run, changes))

    case event do
      "ok" ->
        Issues.record(check, :ok, at: at)

      "fail" ->
        Issues.record(check, :down,
          at: at,
          note: failure(run),
          title: "#{label(service, name)} failed"
        )

      _ ->
        nil
    end

    :ok
  end

  defp find_run(check, id, event) do
    found =
      cond do
        is_binary(id) ->
          Repo.get_by(JobRun, check_id: check.id, run: id)

        event == "start" ->
          nil

        true ->
          Repo.one(
            from r in JobRun,
              where: r.check_id == ^check.id and r.result == :running,
              order_by: [desc: r.started_at],
              limit: 1
          )
      end

    found || %JobRun{check_id: check.id, run: (is_binary(id) && id) || Ecto.UUID.generate()}
  end

  def label(%Service{slug: name, name: full}, name), do: full
  def label(_, name), do: name

  defp failure(%JobRun{tail: tail}) when is_binary(tail),
    do:
      tail
      |> String.split("
",
        trim: true
      )
      |> List.last()

  defp failure(%JobRun{exit_code: code}) when is_integer(code), do: "Exit code #{code}"
  defp failure(_), do: "Reported as failed"

  defp tail(text) do
    size = byte_size(text)

    if size > @tail_bytes,
      do: binary_part(text, size - @tail_bytes, @tail_bytes) |> String.replace_invalid(""),
      else: text
  end

  defp service(%Key{kind: :app, service_id: id}, _), do: {:ok, Repo.get!(Service, id)}

  defp service(%Key{kind: :machine, machine_id: machine}, %{"service" => slug})
       when is_binary(slug) do
    case Repo.get_by(Service, machine_id: machine, slug: slug) do
      nil -> {:error, "unknown_service", "No service #{inspect(slug)} on this machine."}
      service -> {:ok, service}
    end
  end

  defp service(_, _), do: {:error, "bad_line", "Needs a service."}

  # A machine may log without naming a service.
  defp log_service(%Key{kind: :machine}, line) when not is_map_key(line, "service"),
    do: {:ok, nil}

  defp log_service(key, line), do: service(key, line)

  defp machine(%Key{machine_id: id}, nil), do: id
  defp machine(_, service), do: service.machine_id

  defp check(service, name, type, fail_after) do
    Repo.get_by(Check, service_id: service.id, name: name) ||
      Repo.insert!(%Check{
        service_id: service.id,
        name: name,
        type: type,
        source: :reported,
        fail_after: fail_after
      })
  end

  defp seen(%Key{} = key) do
    now = DateTime.utc_now()
    service = key.service_id && Repo.get!(Service, key.service_id)
    machine = key.machine_id || (service && service.machine_id)
    Repo.update_all(from(m in Machine, where: m.id == ^machine), set: [last_seen_at: now])
    Repo.update_all(from(k in Key, where: k.id == ^key.id), set: [used_at: now])
    service
  end

  defp at(%{"at" => text}, now) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} ->
        if DateTime.compare(at, now) == :gt,
          do: now,
          else: %{at | microsecond: {elem(at.microsecond, 0), 6}}

      _ ->
        now
    end
  end

  defp at(_, now), do: now

  defp number(v) when is_number(v), do: v / 1
  defp number(_), do: nil
end
