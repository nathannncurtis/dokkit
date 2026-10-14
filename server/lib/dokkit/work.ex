defmodule Dokkit.Work do
  @moduledoc """
  What a machine is asked to do besides report: fetch the newer program, or send an iMessage
  from a Mac. A run is queued here, the program holds a long poll open to take it, and sends
  back its output and result.
  """
  import Ecto.Query
  alias Dokkit.{Repo, WorkRun}

  @max_output 256 * 1024
  @imessage "dokkit:imessage"
  @update "dokkit:update"
  @scan "dokkit:scan"
  @nudge "dokkit:nudge"

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
    if program_version(), do: queue(%WorkRun{machine_id: machine_id, name: @update, by: by})
  end

  @doc "Asks a machine to look itself over again and send what it finds. Takes no parameters."
  def scan(machine_id, by), do: queue(%WorkRun{machine_id: machine_id, name: @scan, by: by})

  @doc """
  Tells a connected program to start its machine's updater now. It carries no version and
  no parameters; the updater asks for what to install. One waiting nudge is enough.
  """
  def nudge(machine_id) do
    unless Repo.exists?(
             from r in WorkRun,
               where: r.machine_id == ^machine_id and r.name == @nudge and r.state == :queued
           ),
           do: queue(%WorkRun{machine_id: machine_id, name: @nudge, by: "update"})
  end

  @doc """
  The newest nudge for a machine: when it was asked, how it ended and what the machine said, or
  nil. A nudge nobody took in a day is `expired`.
  """
  def last_nudge(machine_id) do
    run =
      Repo.one(
        from r in WorkRun,
          where: r.machine_id == ^machine_id and r.name == @nudge,
          order_by: [desc: r.inserted_at],
          limit: 1
      )

    run &&
      %{
        asked_at: run.inserted_at,
        state:
          if(run.state == :refused and is_nil(run.started_at), do: :expired, else: run.state),
        answered_at: run.finished_at,
        output: run.output
      }
  end

  @doc "Queues a run that sends an iMessage from this Mac. It is offered only to this machine."
  def imessage(machine_id, to, text, alert_id \\ nil) do
    queue(%WorkRun{
      machine_id: machine_id,
      name: @imessage,
      by: "alert",
      alert_id: alert_id,
      payload: %{"to" => to, "text" => text}
    })
  end

  defp queue(%WorkRun{machine_id: machine_id} = run) do
    run = Repo.insert!(run)
    Phoenix.PubSub.broadcast(Dokkit.PubSub, "work:#{machine_id}", :work)
    Dokkit.Issues.changed(false)
    run
  end

  @doc "What the program is told beside the run's name: an iMessage run's own fields."
  def extras(%WorkRun{payload: %{"to" => to, "text" => text}}), do: %{to: to, text: text}
  def extras(_), do: %{}

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
        from r in WorkRun,
          where: r.state == :queued and r.machine_id == ^machine_id,
          order_by: r.inserted_at,
          limit: 1
      )

    taken =
      run &&
        Repo.update_all(from(r in WorkRun, where: r.id == ^run.id and r.state == :queued),
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
    do:
      machine_id
      |> finish(run_id, state: :refused, output: String.slice(why, 0, 500))
      |> answered(run_id)

  def result(machine_id, run_id, %{"exit_code" => code} = params) when is_integer(code) do
    took = params["duration_ms"]

    machine_id
    |> finish(run_id,
      state: if(code == 0, do: :ok, else: :fail),
      exit_code: code,
      duration_ms: is_integer(took) && took >= 0 && took
    )
    |> answered(run_id)
  end

  def result(_, _, _), do: :error

  defp answered(:ok, run_id) do
    Dokkit.Alerts.answered(run_id)
    :ok
  end

  defp answered(other, _), do: other

  defp finish(machine_id, run_id, set) do
    set = for {k, v} <- set, v != false, do: {k, v}
    write(running(machine_id, run_id), set: [finished_at: DateTime.utc_now()] ++ set)
  end

  defp running(machine_id, run_id) do
    from r in WorkRun,
      where: r.id == ^run_id and r.state == :running and r.machine_id == ^machine_id
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
      from(r in WorkRun,
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
          from(r in WorkRun,
            where: r.state == :queued and r.inserted_at < ^DateTime.add(now, -1, :day)
          ),
          :refused,
          "The machine did not take this run."
        )

    if n > 0, do: Dokkit.Issues.changed(false)
    n
  end
end
