defmodule Dokkit.Deploys do
  @moduledoc "A deploy is a service's version changing on its machine, however that was seen."
  import Ecto.Query
  alias Dokkit.{Deploy, Repo, Service}

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

  def list(opts \\ []) do
    query = from d in Deploy, order_by: [desc: d.at], preload: [service: :machine]
    query = if id = opts[:service], do: where(query, [d], d.service_id == ^id), else: query
    Repo.all(limit(query, ^(opts[:limit] || 100)))
  end
end
