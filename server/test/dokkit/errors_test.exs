defmodule Dokkit.ErrorsTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Keys, Machine, Read, Repo, Service}

  test "reports are grouped by type and the app's own frames, and no message is kept", %{
    conn: conn
  } do
    machine = Repo.insert!(%Machine{name: "vault"})

    service =
      Repo.insert!(%Service{machine_id: machine.id, slug: "portal", name: "Upload portal"})

    {app, _} = Keys.mint(:app, %{service_id: service.id})
    as = put_req_header(build_conn(), "authorization", "Bearer " <> app)

    report = fn line ->
      post(as, "/api/v1/errors", %{
        type: "TimeoutError",
        release: "2.3.0",
        handled: true,
        message: "patient 4411 timed out",
        frames: [
          %{file: "site-packages/httpx/_client.py", function: "send", line: 914, own: false},
          %{file: "app/worker.py", function: "run_job", line: line, own: true}
        ],
        tags: %{route: "/upload", nested: %{no: "thanks"}}
      })
    end

    assert json_response(report.(212), 200)
    assert json_response(report.(214), 200)
    assert json_response(post(as, "/api/v1/errors", %{type: "ValueError"}), 200)
    assert json_response(post(as, "/api/v1/errors", %{}), 422)
    assert json_response(post(build_conn(), "/api/v1/errors", %{type: "X"}), 401)

    assert [%{type: "ValueError", count: 1}, %{type: "TimeoutError", count: 2} = group] =
             Read.errors() |> Enum.sort_by(& &1.count)

    assert group.top == "app/worker.py in run_job"
    one = Read.error(group.id)
    assert one.tags == %{"route" => "/upload"}
    refute inspect(Repo.all(Dokkit.ErrorEvent)) =~ "4411"

    conn = signed_in(conn)
    {:ok, _, html} = live(conn, "/errors")
    assert html =~ "TimeoutError"
    assert html =~ "Caught by the app"
    {:ok, _, html} = live(conn, "/errors/#{group.id}")
    assert html =~ "run_job"
    assert html =~ "line 214"
    assert html =~ "2 reports"
  end
end
