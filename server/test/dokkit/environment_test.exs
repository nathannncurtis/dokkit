defmodule Dokkit.EnvironmentTest do
  use DokkitWeb.ConnCase, async: true
  import Ecto.Query
  alias Dokkit.{Check, ErrorGroup, Issues, Keys, Log, Machine, Repo, Service}

  setup do
    home = Repo.insert!(%Machine{name: "Apps", kind: :group})

    base =
      Repo.insert!(%Service{machine_id: home.id, slug: "scanner", name: "Scanner", kind: :app})

    {key, _} = Keys.mint(:app, %{service_id: base.id})
    %{base: base, key: key}
  end

  defp dev(base), do: Repo.get_by!(Service, machine_id: base.machine_id, slug: "scanner~dev")

  defp lines(env),
    do:
      [
        %{type: "custom", check: "queue", state: "down", note: "stuck"},
        %{type: "beat", name: "tick"},
        %{type: "metric", name: "queue.depth", value: 3},
        %{type: "stats", document: %{"schema" => 1}},
        %{type: "deploy", version: "9.9.9"},
        %{type: "job", name: "sync", event: "ok"},
        %{type: "log", level: "info", msg: "hello"}
      ]
      |> Enum.map(&Jason.encode!(Map.put(&1, :environment, env)))

  test "lines from another environment land on a separate service that never alerts", %{
    key: key,
    base: base
  } do
    assert %{"accepted" => 7, "refused" => []} = json_response(report(key, lines("dev")), 200)

    dev = dev(base)
    assert %{environment: "dev", name: "Scanner (dev)", kind: :app} = dev
    assert Repo.aggregate(from(c in Check, where: c.service_id == ^dev.id), :count) == 4
    assert Repo.aggregate(from(c in Check, where: c.service_id == ^base.id), :count) == 0
    assert %{version: "9.9.9"} = Repo.get!(Service, dev.id)
    assert is_nil(Repo.get!(Service, base.id).version)
    assert Repo.aggregate(from(l in Log, where: l.service_id == ^dev.id), :count) == 1
    assert Repo.aggregate(from(l in Log, where: l.service_id == ^base.id), :count) == 0
    assert Repo.get!(Service, base.id).environment == "production"

    down = Jason.encode!(%{type: "custom", check: "queue", state: "down", environment: "dev"})
    report(key, [down, down])
    [issue] = Issues.open_list()
    assert issue.service_id == dev.id
    assert is_nil(Dokkit.Alerts.plan(issue, dev, DateTime.utc_now()))
  end

  test "production, a missing environment and a bad one stay on the app's own service", %{
    key: key,
    base: base
  } do
    for env <- ["production", "Production", nil, "no spaces allowed"],
        do: json_response(report(key, lines(env)), 200)

    assert Repo.aggregate(from(s in Service), :count) == 1
    assert Repo.aggregate(from(c in Check, where: c.service_id == ^base.id), :count) == 4
  end

  test "a declared service keeps its environment whatever a line says", %{key: key, base: base} do
    Repo.update!(Ecto.Changeset.change(base, declared: %{"schema" => 1}, environment: "staging"))
    json_response(report(key, lines("dev")), 200)
    assert Repo.aggregate(from(s in Service), :count) == 1
    assert Repo.get!(Service, base.id).environment == "staging"
  end

  test "an app key can make only a few other environments", %{key: key} do
    for env <- ~w(a b c d e) do
      report(key, [Jason.encode!(%{type: "beat", name: "t", environment: env})])
    end

    assert Repo.aggregate(from(s in Service, where: like(s.slug, "scanner~%")), :count) == 5

    assert %{"refused" => [%{"code" => "too_many_environments"}]} =
             json_response(
               report(key, [Jason.encode!(%{type: "beat", name: "t", environment: "g"})]),
               200
             )
  end

  test "errors from another environment are grouped on that environment's service", %{
    key: key,
    base: base
  } do
    for env <- ["dev", "production"] do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> key)
      |> post("/api/v1/errors", %{type: "TimeoutError", frames: [], environment: env})
      |> json_response(200)
    end

    assert Repo.aggregate(from(g in ErrorGroup, where: g.service_id == ^dev(base).id), :count) ==
             1

    assert Repo.aggregate(from(g in ErrorGroup, where: g.service_id == ^base.id), :count) == 1
  end

  test "an event from Sentry's SDKs carries its environment", %{key: key, base: base} do
    event =
      Jason.encode!(%{
        environment: "dev",
        exception: %{values: [%{type: "TimeoutError", value: "x"}]}
      })

    envelope =
      Enum.join(
        [~s({"dsn":"https://#{key}@dokkit.example/1"}), ~s({"type":"event"}), event],
        "\n"
      )

    build_conn()
    |> put_req_header("content-type", "application/x-sentry-envelope")
    |> post("/api/1/envelope/", envelope)
    |> json_response(200)

    assert [_] = Repo.all(from g in ErrorGroup, where: g.service_id == ^dev(base).id)
  end
end
