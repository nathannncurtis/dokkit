defmodule Dokkit.Releases do
  @moduledoc "The signed releases this server holds for the updaters to fetch. See spec/updates.md."
  import Ecto.Query
  alias Dokkit.{Machine, Repo}

  @sums "SHA256SUMS"
  @sig "SHA256SUMS.sig"

  def dir, do: Application.fetch_env!(:dokkit, :releases)

  @doc "A version or file name: letters, digits, dots, dashes and underscores, not starting with a dot."
  def name?(name),
    do:
      is_binary(name) and name =~ ~r/\A[A-Za-z0-9_-][A-Za-z0-9._-]*\z/ and byte_size(name) <= 128

  def path(version, file) do
    if name?(version) and name?(file), do: Path.join([dir(), version, file])
  end

  @doc "A place in the releases folder to write a body before it is renamed into place."
  def incoming do
    folder = Path.join(dir(), ".incoming")
    File.mkdir_p!(folder)
    Path.join(folder, Base.encode16(:crypto.strong_rand_bytes(8)))
  end

  def commit(tmp, version, file) do
    target = path(version, file)
    File.mkdir_p!(Path.dirname(target))
    File.rename!(tmp, target)
  end

  def delete(version) do
    if name?(version) and File.dir?(Path.join(dir(), version)) do
      File.rm_rf!(Path.join(dir(), version))
      true
    end
  end

  @doc "Every version held, newest first, with its files and whether the signed list is there."
  def list do
    versions =
      case File.ls(dir()) do
        {:ok, names} -> Enum.filter(names, &(name?(&1) and File.dir?(Path.join(dir(), &1))))
        _ -> []
      end

    for v <- versions do
      files =
        v |> then(&Path.join(dir(), &1)) |> File.ls!() |> Enum.filter(&name?/1) |> Enum.sort()

      %{version: v, files: files, complete: @sums in files and @sig in files}
    end
    |> Enum.sort_by(&key(&1.version), :desc)
  end

  def complete?(version), do: Enum.any?(list(), &(&1.version == version and &1.complete))

  @doc "The newest version the server holds completely, or nil."
  def newest do
    case Enum.find(list(), & &1.complete) do
      %{version: v} -> if parse(v), do: v
      _ -> nil
    end
  end

  @doc "`v` and three numbers, as a tuple, or nil."
  def parse(version) when is_binary(version) do
    case Regex.run(~r/\Av(\d{1,9})\.(\d{1,9})\.(\d{1,9})\z/, version) do
      [_, a, b, c] -> {String.to_integer(a), String.to_integer(b), String.to_integer(c)}
      _ -> nil
    end
  end

  def parse(_), do: nil

  # Anything that is not a version is older than every real one.
  defp key(version), do: parse(version) || {-1, 0, 0}

  def newer?(a, b), do: key(a) > key(b)

  @doc "Sets the wanted version on one machine, or on every machine with an updater."
  def approve(version, machine_id \\ :all) do
    cond do
      not is_binary(version) or parse(version) == nil ->
        {:error, "bad_version", "version is v and three numbers, such as v1.2.3."}

      not complete?(version) ->
        {:error, "not_held",
         "This server does not hold #{version} completely: it needs SHA256SUMS and SHA256SUMS.sig."}

      machine_id == :all ->
        {n, _} = set(from(m in Machine, where: m.has_updater), version)
        {:ok, n}

      true ->
        with {:ok, id} <- Ecto.UUID.cast(machine_id),
             {1, _} <- set(from(m in Machine, where: m.id == ^id), version) do
          {:ok, 1}
        else
          _ -> {:error, "not_found", "No such thing."}
        end
    end
    |> tap(fn r -> if match?({:ok, _}, r), do: Dokkit.Issues.changed(false) end)
  end

  @doc "Whether an update to `held` can be offered to the machine."
  def movable?(m, held) do
    m.has_updater and held != nil and
      (newer?(held, m.program_version) or (m.hosts_server and newer?(held, m.server_version))) and
      (is_nil(m.wanted_version) or m.update_ok == false)
  end

  @doc "What became of the last update asked of a machine, or nil."
  def outcome(%{wanted_version: nil, update_ok: true, update_version: v}), do: "Updated to #{v}"

  def outcome(%{update_ok: false, update_version: v, update_note: note}),
    do: "Update to #{v} failed: #{note}"

  def outcome(%{wanted_version: v}) when is_binary(v), do: "Asked to move to #{v}"
  def outcome(_), do: nil

  defp set(query, version) do
    result =
      Repo.update_all(query,
        set: [
          wanted_version: version,
          update_started_at: DateTime.utc_now(),
          update_asked_at: nil,
          update_version: nil,
          update_ok: nil,
          update_note: nil,
          update_at: nil
        ]
      )

    for id <- Repo.all(from m in subquery(query), where: m.has_updater, select: m.id),
        do: Dokkit.Work.nudge(id)

    result
  end

  @parts [program_version: "program", server_version: "server", updater_version: "updater"]

  @doc "Remembers what the machine reports, and answers the version it should move to, or nil."
  def ask(machine_id, params) do
    reported = for {field, key} <- @parts, is_binary(params[key]), do: {field, params[key]}

    change =
      [has_updater: true, hosts_server: is_binary(params["server"])] ++
        reported ++ if(is_binary(params["server"]), do: [], else: [server_version: nil])

    Repo.update_all(from(m in Machine, where: m.id == ^machine_id), set: change)
    m = Repo.get!(Machine, machine_id)

    parts =
      [
        m.program_version,
        m.updater_version | if(m.hosts_server, do: [m.server_version], else: [])
      ]
      |> Enum.reject(&is_nil/1)

    if m.wanted_version && complete?(m.wanted_version) &&
         Enum.any?(parts, &(&1 != m.wanted_version)) do
      if m.update_started_at && is_nil(m.update_asked_at),
        do:
          Repo.update_all(from(x in Machine, where: x.id == ^machine_id),
            set: [update_asked_at: DateTime.utc_now()]
          )

      m.wanted_version
    end
  end

  @doc "Keeps the last result, and clears the wanted version when it worked."
  def result(machine_id, %{"version" => version, "ok" => ok} = params)
      when is_binary(version) and is_boolean(ok) do
    note = params["note"]

    if is_nil(note) or (is_binary(note) and String.length(note) <= 2000) do
      change =
        [update_version: version, update_ok: ok, update_note: note, update_at: DateTime.utc_now()] ++
          if(ok, do: [wanted_version: nil], else: [])

      Repo.update_all(from(m in Machine, where: m.id == ^machine_id), set: change)
      Dokkit.Issues.changed(false)
      :ok
    else
      :error
    end
  end

  def result(_, _), do: :error
end
