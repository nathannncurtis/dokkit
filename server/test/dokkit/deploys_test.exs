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

    other = Repo.insert!(%Machine{name: "press", kind: :enrolled, program_version: "0.1.0"})

    Repo.insert!(%Service{
      machine_id: other.id,
      slug: "portal",
      name: "Upload portal",
      version: "2.10.0"
    })

    {:ok, _, html} = live(signed_in(conn), "/versions")
    assert html =~ ~s(<span class="tag warn">2.4.0</span>)
    assert html =~ "<span>2.10.0</span>"
    assert html =~ "dokkit"
  end

  test "an app on many PCs keeps a version for each, and none of it is a deploy", %{conn: conn} do
    # Its own machine name: tests run side by side and a shared name makes them wait on each other.
    machine = Repo.insert!(%Machine{name: "desks", kind: :group})

    service =
      Repo.insert!(%Service{machine_id: machine.id, slug: "scanner", name: "Scanner", kind: :app})

    {app, _} = Keys.mint(:app, %{service_id: service.id})

    for {host, version} <- [
          {"PC-014", "3.9.0"},
          {"PC-020", "3.10.0"},
          {"PC-031", "3.10.0"},
          {"PC-014", "3.9.1"}
        ] do
      report(app, [%{type: "deploy", version: version, host: host}])
    end

    assert Dokkit.Deploys.list(service: service.id) == []
    assert Repo.get!(Service, service.id).version == nil

    assert [
             %{
               name: "Scanner",
               hosts: 3,
               versions: [
                 %{version: "3.10.0", hosts: two},
                 %{version: "3.9.1", hosts: ["PC-014"]}
               ]
             }
           ] =
             Read.apps()

    assert Enum.sort(two) == ["PC-020", "PC-031"]

    {:ok, _, html} = live(signed_in(conn), "/versions")
    assert html =~ "Desktop apps"
    assert html =~ "3 machines"
    assert html =~ "PC-014"
  end

  test "an app let deploy others records a deploy of each app it installs, on the machine it went to",
       %{conn: conn} do
    group = Repo.insert!(%Machine{name: "shelf", kind: :group})

    app = fn slug, name ->
      Repo.insert!(%Service{machine_id: group.id, slug: slug, name: name, kind: :app})
    end

    installer = app.("installer", "Installer")
    printer = app.("label-printer", "Label Printer")
    {key, _} = Keys.mint(:app, %{service_id: installer.id})
    deploy = &report(key, [Map.merge(%{type: "deploy", host: "DESK-101"}, &1)])

    assert %{"refused" => [%{"code" => "not_allowed"}]} =
             json_response(deploy.(%{service: "Label Printer", version: "1.0.0"}), 200)

    assert Dokkit.Deploys.list(service: printer.id) == []
    assert Repo.get_by(Dokkit.Install, service_id: installer.id) == nil

    deploy.(%{service: "Installer", version: "0.9.0"})
    assert Repo.get_by(Dokkit.Install, service_id: installer.id).version == "0.9.0"

    {:ok, view, _} = live(signed_in(conn), "/s/#{installer.id}")
    view |> element("button", "Let it") |> render_click()
    assert Repo.reload!(installer).deployer

    deploy.(%{service: "Label Printer", version: "1.0.0"})
    deploy.(%{service: "Label Printer", version: "1.0.0"})
    deploy.(%{service: "Label Printer", version: "1.1.0"})

    assert [%{from: "1.0.0", version: "1.1.0"}, %{from: nil, version: "1.0.0"}] =
             Dokkit.Deploys.list(service: printer.id)

    assert [%{machine: "DESK-101", how: "deployed", by: "Installer"} | _] =
             Read.deploys(service: printer.id)

    assert %{"refused" => [%{"code" => "unknown_service"}]} =
             json_response(deploy.(%{service: "Nothing Here", version: "1"}), 200)

    as = put_req_header(build_conn(), "authorization", "Bearer " <> key)
    no_host = %{service: "label-printer", version: "1.2.0"}
    assert json_response(post(as, "/api/v1/deploys", no_host), 422)

    assert json_response(post(as, "/api/v1/deploys", Map.put(no_host, :host, "DESK-102")), 200)
    assert [%{version: "1.2.0", machine: "DESK-102"} | _] = Read.deploys(service: printer.id)

    {:ok, _, html} = live(signed_in(conn), "/deploys")
    assert html =~ "Deployed by Installer"
    assert html =~ "DESK-101"
  end
end
