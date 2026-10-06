defmodule Dokkit.Tasks do
  @moduledoc """
  Tasks: named commands a dokkit.toml offers. One is runnable only while the command a person
  accepted is still the command in the file. A changed command waits to be accepted again.
  """
  import Ecto.Query
  alias Dokkit.{Repo, Task, TaskRun}

  @max_output 256 * 1024

  @doc "Takes the tasks of a declared file. The file owns them, so ones it no longer lists go."
  def declared(service, tasks) do
    tasks =
      for %{"id" => id, "run" => run} <- List.wrap(tasks),
          is_binary(id),
          is_binary(run),
          do: {id, run}

    names = for {id, _} <- tasks, do: id
    Repo.delete_all(from t in Task, where: t.service_id == ^service.id and t.name not in ^names)

    for {id, run} <- tasks do
      case Repo.get_by(Task, machine_id: service.machine_id, name: id) do
        nil ->
          Repo.insert!(%Task{
            machine_id: service.machine_id,
            service_id: service.id,
            name: id,
            command: run
          })

        task ->
          Repo.update!(Ecto.Changeset.change(task, command: run, service_id: service.id))
      end
    end
  end

  defp offered,
    do:
      from(t in Task,
        where:
          fragment(
            "? IS DISTINCT FROM ? AND ? IS DISTINCT FROM ?",
            t.accepted,
            t.command,
            t.dismissed,
            t.command
          )
      )

  defp runnable, do: from(t in Task, where: t.accepted == t.command)

  @doc "What a machine may be asked to run: each accepted task and the command that was accepted."
  def accepted_for(machine_id) do
    for t <-
          Repo.all(
            from t in Task,
              where: t.machine_id == ^machine_id and not is_nil(t.accepted),
              order_by: t.name
          ),
        do: %{task: t.name, command_sha256: sha256(t.accepted)}
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

  @doc "Accepts or dismisses the command the person was shown, and nothing newer."
  def decide(id, command, field) when field in [:accepted, :dismissed] do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Task{command: ^command} = task <- Repo.get(Task, id) do
      Repo.update!(Ecto.Changeset.change(task, [{field, command}]))
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
          where: r.state == :queued and t.machine_id == ^machine_id and t.accepted == t.command,
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

  def sha256(command), do: Base.encode16(:crypto.hash(:sha256, command), case: :lower)
end
