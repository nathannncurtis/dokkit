defmodule Mix.Tasks.Dokkit.Job do
  @shortdoc "Adds a job to watch and prints its ping addresses"
  @moduledoc """
      mix dokkit.job MACHINE NAME [--schedule "0 1 * * *"] [--grace 30m] [--max-runtime 1h]

  Until the interface can do this. The key in the addresses is shown once.
  """
  use Mix.Task
  alias Dokkit.{Check, Keys, Machine, Repo, Service}

  def run(args) do
    Mix.Task.run("app.start")

    {opts, [machine, name], _} =
      OptionParser.parse(args, strict: [schedule: :string, grace: :string, max_runtime: :string])

    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

    machine =
      Repo.get_by(Machine, name: machine) || Repo.insert!(%Machine{name: machine, kind: :seen})

    service =
      Repo.get_by(Service, machine_id: machine.id, slug: slug) ||
        Repo.insert!(%Service{machine_id: machine.id, slug: slug, name: name, kind: :job})

    config = for {k, v} <- opts, into: %{}, do: {to_string(k), v}

    Repo.insert!(
      %Check{service_id: service.id, name: slug, type: :job, fail_after: 1, config: config},
      on_conflict: [set: [config: config]],
      conflict_target: [:service_id, :name]
    )

    {key, _} = Keys.mint(:app, %{service_id: service.id, label: name})
    base = DokkitWeb.Endpoint.url() <> "/api/v1/in/#{key}/job/#{slug}"
    Mix.shell().info("#{base}/start\n#{base}/ok\n#{base}/fail")
  end
end
