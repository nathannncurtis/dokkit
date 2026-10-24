defmodule Dokkit.Deploys do
  @moduledoc "A deploy is a service's version changing on its machine, however that was seen."
  import Ecto.Query
  alias Dokkit.{Deploy, Install, Repo, Service}

  @doc "Notes a service's version. The first one seen is only stored; a change after that is a deploy."
  def record(%Service{} = service, version, opts \\ []) when is_binary(version) do
    version = String.slice(version, 0, 100)

    if version not in ["", service.version] do
      if service.version do
        Repo.insert!(%Deploy{
          service_id: service.id,
          from: service.version,
          version: version,
          commit: opts[:commit],
          by: opts[:by],
          how: opts[:how] || "noticed",
          at: DateTime.utc_now()
        })
      end

      Repo.update!(Ecto.Changeset.change(service, version: version))
      Dokkit.Issues.changed(false)
    end

    :ok
  end

  @doc """
  Notes the version of an app on one of the many hosts it runs on. That is not a deploy:
  forty PCs on two versions would otherwise flip the service back and forth all day.
  """
  def installed(%Service{id: id}, machine_id, version, at) do
    Repo.insert_all(
      Install,
      [
        [
          service_id: id,
          machine_id: machine_id,
          version: String.slice(version, 0, 100),
          seen_at: at
        ]
      ],
      on_conflict: {:replace, [:version, :seen_at]},
      conflict_target: [:service_id, :machine_id]
    )

    :ok
  end

  @doc "An app installed on a host by another app, a deployer. A new version there is a deploy on that host."
  def deployed(%Service{} = service, machine_id, version, by, at) do
    version = String.slice(version, 0, 100)
    from = Repo.get_by(Install, service_id: service.id, machine_id: machine_id)

    cond do
      version == "" ->
        :ok

      from && from.version == version ->
        installed(service, machine_id, version, at)

      true ->
        Repo.insert!(%Deploy{
          service_id: service.id,
          machine_id: machine_id,
          from: from && from.version,
          version: version,
          by: by,
          how: "deployed",
          at: at
        })

        installed(service, machine_id, version, at)
        Dokkit.Issues.changed(false)
    end
  end

  @doc "Apps that run on many hosts: each with its versions, newest first, and the hosts on each."
  def apps do
    Repo.all(from i in Install, order_by: [desc: i.seen_at], preload: [:service, :machine])
    |> Enum.group_by(& &1.service)
    |> Enum.map(fn {service, installs} ->
      versions =
        installs
        |> Enum.group_by(& &1.version, & &1.machine.name)
        |> Enum.sort_by(fn {v, _} -> number(v) end, :desc)

      %{service: service, hosts: length(installs), versions: versions}
    end)
    |> Enum.sort_by(& &1.service.name)
  end

  @doc "A version as its numbers, so 2.10 is newer than 2.9."
  def number(version), do: for([n] <- Regex.scan(~r/\d+/, version), do: String.to_integer(n))

  def list(opts \\ []) do
    query = from d in Deploy, order_by: [desc: d.at], preload: [:machine, service: :machine]
    query = if id = opts[:service], do: where(query, [d], d.service_id == ^id), else: query
    Repo.all(limit(query, ^(opts[:limit] || 100)))
  end
end
