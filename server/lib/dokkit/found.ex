defmodule Dokkit.Found do
  @moduledoc """
  What a scan found on a machine and nobody has decided about yet. Watching one makes a
  service with one check, which `dokkit watch` on that machine then runs.
  """
  import Ecto.Query
  alias Dokkit.{Check, Finding, Repo, Service}

  @max 2000
  @runs ~w(http tcp process windows-service)a

  @doc "Takes a proposal file. Only what can be checked today is kept: running Windows services and listening ports."
  def propose(machine_id, %{"found" => %{} = found} = body) do
    watched =
      MapSet.new(checks(machine_id), fn c ->
        {c.type, to_string(c.config["name"] || c.config["port"])}
      end)

    services =
      for %{"name" => name, "state" => "running"} = s <- List.wrap(found["services"]),
          body["os"] == "windows",
          is_binary(name),
          {:"windows-service", name} not in watched,
          do: {"service", name, %{"label" => text(s["display"]) || name, "saw" => "Running"}}

    ports =
      for %{"port" => port} = p <- List.wrap(found["ports"]),
          {n, ""} <- [Integer.parse(to_string(port))],
          n in 1..65535,
          {:tcp, to_string(n)} not in watched,
          do:
            {"port", to_string(n),
             %{"label" => "Port #{n}", "saw" => text(p["program"]) || "Listening"}}

    now = DateTime.utc_now()

    rows =
      for {kind, key, detail} <- Enum.take(services ++ ports, @max) do
        %{
          id: Ecto.UUID.generate(),
          machine_id: machine_id,
          kind: kind,
          key: key,
          detail: detail,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Finding, rows,
      on_conflict: {:replace, [:detail, :updated_at]},
      conflict_target: [:machine_id, :kind, :key]
    )

    Dokkit.Issues.changed(false)
    {:ok, Repo.aggregate(from(f in waiting(), where: f.machine_id == ^machine_id), :count)}
  end

  def propose(_, _), do: :error

  defp text(value), do: is_binary(value) && value != "" && String.slice(value, 0, 200)

  defp waiting, do: from(f in Finding, where: not f.dismissed)

  def list,
    do: Repo.all(from f in waiting(), order_by: [f.kind, f.key], preload: :machine)

  def count, do: Repo.aggregate(waiting(), :count)

  def dismiss(ids) do
    Repo.update_all(from(f in Finding, where: f.id in ^cast(ids)), set: [dismissed: true])
    Dokkit.Issues.changed(false)
  end

  @doc "Starts watching each found thing: a service of its machine with one check."
  def watch(ids) do
    for f <- Repo.all(from f in Finding, where: f.id in ^cast(ids)) do
      {slug, name, type, check, config} =
        case f.kind do
          "service" ->
            {slug(f.key), f.detail["label"], :"windows-service", "windows-service",
             %{"name" => f.key}}

          "port" ->
            {"port-" <> f.key, "#{f.detail["saw"]} on port #{f.key}", :tcp, "tcp",
             %{"port" => String.to_integer(f.key)}}
        end

      service =
        Repo.get_by(Service, machine_id: f.machine_id, slug: slug) ||
          Repo.insert!(%Service{machine_id: f.machine_id, slug: slug, name: name})

      Repo.get_by(Check, service_id: service.id, name: check) ||
        Repo.insert!(%Check{service_id: service.id, name: check, type: type, config: config})

      Repo.delete!(f)
    end

    Dokkit.Issues.changed(false)
  end

  defp slug(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
  end

  defp cast(ids), do: for(id <- List.wrap(ids), {:ok, id} <- [Ecto.UUID.cast(id)], do: id)

  @doc "The checks of a machine that no file declares and the program can run."
  def checks(machine_id) do
    Repo.all(
      from c in Check,
        join: s in assoc(c, :service),
        where: s.machine_id == ^machine_id and c.source != :file and c.type in ^@runs,
        select: %{service: s.slug, name: c.name, type: c.type, config: c.config}
    )
  end
end
