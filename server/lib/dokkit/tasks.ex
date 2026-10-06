defmodule Dokkit.Tasks do
  @moduledoc """
  Tasks: named commands a dokkit.toml offers. One is runnable only while the command and the pin
  a person accepted are still the ones the file offers. The pin is the program's hash of the
  command, the file's path and the script it runs. A change to either waits to be accepted again.
  """
  import Ecto.Query
  alias Dokkit.{Repo, Task, TaskRun}

  @max_output 256 * 1024

  @doc "Takes the tasks of a declared file. The file owns them, so ones it no longer lists go."
  def declared(service, tasks) do
    tasks =
      for %{"id" => id, "run" => run} = t <- List.wrap(tasks),
          is_binary(id),
          is_binary(run),
          # Names that start this way are Dokkit's own.
          not String.starts_with?(id, "dokkit:"),
          do: {id, run, if(is_binary(t["pin"]), do: t["pin"])}

    names = for {id, _, _} <- tasks, do: id
    Repo.delete_all(from t in Task, where: t.service_id == ^service.id and t.name not in ^names)

    for {id, run, pin} <- tasks do
      case Repo.get_by(Task, machine_id: service.machine_id, name: id) do
        nil ->
          Repo.insert!(%Task{
            machine_id: service.machine_id,
            service_id: service.id,
            name: id,
            command: run,
            pin: pin
          })

        task ->
          Repo.update!(
            Ecto.Changeset.change(task, command: run, pin: pin, service_id: service.id)
          )
      end
    end
  end

  defp offered,
    do:
      from(t in Task,
        where:
          not is_nil(t.pin) and
            fragment(
              "(? IS DISTINCT FROM ? OR ? IS DISTINCT FROM ?) AND ? IS DISTINCT FROM ?",
              t.accepted,
              t.command,
              t.accepted_pin,
              t.pin,
              t.dismissed,
              t.command
            )
      )

  defp runnable, do: from(t in Task, where: t.accepted == t.command and t.accepted_pin == t.pin)

  @doc "What a machine may be asked to run: each accepted task and the pin that was accepted."
  def accepted_for(machine_id) do
    for t <-
          Repo.all(
            from t in Task,
              where: t.machine_id == ^machine_id and not is_nil(t.accepted_pin),
              order_by: t.name
          ),
        do: %{task: t.name, command_sha256: t.accepted_pin, as: account(t)}
  end

  def waiting, do: Repo.all(from t in offered(), order_by: t.name, preload: :machine)
  def waiting_count, do: Repo.aggregate(offered(), :count)

  @doc "Accepted tasks, each with its latest run."
  def accepted do
    tasks = Repo.all(from t in runnable(), order_by: t.name, preload: :machine)

    last =
      Map.new(
        Repo.all(
          from r in TaskRun,
            distinct: r.task_id,
            order_by: [r.task_id, desc: r.inserted_at]
        ),
        &{&1.task_id, &1}
      )

    for t <- tasks, do: %{task: t, last: last[t.id]}
  end

  def runs(limit \\ 50) do
    Repo.all(
      from r in TaskRun, order_by: [desc: r.inserted_at], limit: ^limit, preload: [task: :machine]
    )
  end

  @doc "The account a machine runs a task under: an ordinary one, unless it was accepted otherwise."
  def account(%Task{as_system: true}), do: "system"
  def account(%Task{}), do: "ordinary"

  @update "dokkit:update"

  @doc "The version of the program this server holds for machines to fetch, or nil."
  def program_version do
    with dir when is_binary(dir) <- Application.get_env(:dokkit, :programs),
         {:ok, text} <- File.read(Path.join(dir, "version.txt")),
         version when version != "" <- String.trim(text) do
      version
    else
      _ -> nil
    end
  end

  @doc "The file for one kind of machine, such as windows-amd64, or nil."
  def program(target) do
    with dir when is_binary(dir) <- Application.get_env(:dokkit, :programs),
         true <- target =~ ~r/^[a-z0-9]+-[a-z0-9]+$/,
         path =
           Path.join(dir, "dokkit-" <> target <> if(target =~ "windows", do: ".exe", else: "")),
         true <- File.regular?(path) do
      path
    else
      _ -> nil
    end
  end

  @doc """
  Asks a machine to fetch the newer program. It only fetches: a person finishes the update
  on the machine. nil when the server holds no program.
  """
  def update(machine_id, by) do
    if program_version() do
      task =
        Repo.get_by(Task, machine_id: machine_id, name: @update) ||
          Repo.insert!(%Task{
            machine_id: machine_id,
            name: @update,
            command: @update,
            accepted: @update,
            pin: @update,
            accepted_pin: @update
          })

      run(task.id, by)
    end
  end

  @doc "Accepts or dismisses the command the person was shown, and nothing newer."
  def decide(id, command, field, as_system \\ false) when field in [:accepted, :dismissed] do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Task{command: ^command} = task <- Repo.get(Task, id) do
      Repo.update!(
        Ecto.Changeset.change(task, [
          {field, command},
          {:accepted_pin, if(field == :accepted, do: task.pin, else: task.accepted_pin)},
          {:as_system, field == :accepted and as_system}
        ])
      )

      Dokkit.Issues.changed(false)
      :ok
    else
      _ -> :error
    end
  end

  @doc "Queues a run of an accepted task and wakes its machine. nil when there is no such task."
  def run(id, by) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Task{} = task <- Repo.one(from t in runnable(), where: t.id == ^id) do
      run = Repo.insert!(%TaskRun{task_id: task.id, by: by})
      Phoenix.PubSub.broadcast(Dokkit.PubSub, "work:#{task.machine_id}", :work)
      Dokkit.Issues.changed(false)
      run
    else
      _ -> nil
    end
  end

  @doc "Gives a machine its oldest queued run, waiting up to `wait` ms for one to appear."
  def take(machine_id, wait) do
    topic = "work:#{machine_id}"
    Phoenix.PubSub.subscribe(Dokkit.PubSub, topic)

    run =
      claim(machine_id) ||
        receive do
          :work -> claim(machine_id)
        after
          wait -> nil
        end

    Phoenix.PubSub.unsubscribe(Dokkit.PubSub, topic)
    run
  end

  defp claim(machine_id) do
    run =
      Repo.one(
        from r in TaskRun,
          join: t in assoc(r, :task),
          where:
            r.state == :queued and t.machine_id == ^machine_id and t.accepted == t.command and
              t.accepted_pin == t.pin,
          order_by: r.inserted_at,
          limit: 1,
          preload: [task: t]
      )

    taken =
      run &&
        Repo.update_all(from(r in TaskRun, where: r.id == ^run.id and r.state == :queued),
          set: [state: :running, started_at: DateTime.utc_now()]
        )

    if taken == {1, nil} do
      Dokkit.Issues.changed(false)
      run
    end
  end

  @doc "Adds output to a run this machine is running. The last 256 KB are kept."
  def output(machine_id, run_id, chunk) do
    chunk = chunk |> String.replace_invalid("") |> String.replace("\0", "")

    write(
      from(r in running(machine_id, run_id),
        update: [set: [output: fragment("right(? || ?, ?)", r.output, ^chunk, @max_output)]]
      ),
      []
    )
  end

  def result(machine_id, run_id, %{"refused" => why}) when is_binary(why),
    do: finish(machine_id, run_id, state: :refused, output: String.slice(why, 0, 500))

  def result(machine_id, run_id, %{"exit_code" => code} = params) when is_integer(code) do
    took = params["duration_ms"]

    finish(machine_id, run_id,
      state: if(code == 0, do: :ok, else: :fail),
      exit_code: code,
      duration_ms: is_integer(took) && took >= 0 && took
    )
  end

  def result(_, _, _), do: :error

  defp finish(machine_id, run_id, set) do
    set = for {k, v} <- set, v != false, do: {k, v}
    write(running(machine_id, run_id), set: [finished_at: DateTime.utc_now()] ++ set)
  end

  defp running(machine_id, run_id) do
    from r in TaskRun,
      join: t in assoc(r, :task),
      where: r.id == ^run_id and r.state == :running and t.machine_id == ^machine_id
  end

  defp write(query, updates) do
    case Repo.update_all(query, updates) do
      {1, _} ->
        Dokkit.Issues.changed(false)
        :ok

      _ ->
        :error
    end
  end

  @doc """
  Ends runs that are stale: ones running for more than 12 hours, whose result never arrived,
  and ones that sat queued for more than a day. Returns how many it ended.
  """
  def expire(now \\ DateTime.utc_now()) do
    ended = fn query, state, why ->
      {n, _} = Repo.update_all(query, set: [state: state, finished_at: now, output: why])
      n
    end

    # What a stuck run already printed is kept; the reason goes after it.
    stuck =
      from(r in TaskRun,
        where: r.state == :running and r.started_at < ^DateTime.add(now, -12, :hour),
        update: [
          set: [
            state: :fail,
            finished_at: ^now,
            output:
              fragment(
                "right(coalesce(?, '') || ?, ?)",
                r.output,
                ^"\nNo result arrived from the machine.",
                ^@max_output
              )
          ]
        ]
      )

    n =
      elem(Repo.update_all(stuck, []), 0) +
        ended.(
          from(r in TaskRun,
            where: r.state == :queued and r.inserted_at < ^DateTime.add(now, -1, :day)
          ),
          :refused,
          "The machine did not take this run."
        )

    if n > 0, do: Dokkit.Issues.changed(false)
    n
  end
end
