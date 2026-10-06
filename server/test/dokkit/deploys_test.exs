defmodule Dokkit.DeploysTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Keys, Machine, Read, Repo, Service}

  test "a version change is a deploy, whether the program notices it or CI says so", %{conn: conn} do
    machine = Repo.insert!(%Machine{name: "vault", kind: :enrolled})

    service =
      Repo.insert!(%Service{machine_id: machine.id, slug: "portal", name: "Upload portal"})

    {mkey, _} = Keys.mint(:machine, %{machine_id: machine.id})
    {app, _} = Keys.mint(:app, %{service_id: service.id})

    seen = fn v ->
      report(mkey, [%{type: "inventory", services: [%{id: "portal", version: v}]}])
    end

    # The first version seen is not a deploy.
    seen.("2.3.0")
    seen.("2.3.0")
    assert Read.deploys() == []
    seen.("2.3.1")
    assert [%{from: "2.3.0", version: "2.3.1", how: "noticed"}] = Read.deploys()

    as = put_req_header(build_conn(), "authorization", "Bearer " <> app)
    assert json_response(post(as, "/api/v1/deploys", %{version: "2.4.0", by: "ci"}), 200)
    assert json_response(post(as, "/api/v1/deploys", %{}), 422)
    assert Repo.reload!(service).version == "2.4.0"

    report(app, [%{type: "custom", check: "queue", state: "down"}])
    report(app, [%{type: "custom", check: "queue", state: "down"}])
    report(app, [%{type: "custom", check: "queue", state: "down"}])

    assert %{deploy: %{version: "2.4.0", by: "ci"}, issues_since: [%{title: _}]} =
             Read.since_deploy(service.id)

    {:ok, _, html} = live(signed_in(conn), "/deploys")
    assert html =~ "Reported by ci"
    assert html =~ "Noticed by Dokkit"
    assert html =~ "2.3.1"
  end
end
