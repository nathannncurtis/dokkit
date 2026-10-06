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
    report(app, [%{type: "beat", name: "ui", host: "PC-014"}])
    assert %{kind: :seen, last_seen_at: %DateTime{}} = Repo.get_by(Machine, name: "PC-014")
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

  test "an error event from one of Sentry's SDKs becomes a report, and the rest is dropped" do
    machine = Repo.insert!(%Machine{name: "vault"})

    service =
      Repo.insert!(%Service{machine_id: machine.id, slug: "portal", name: "Upload portal"})

    {app, _} = Keys.mint(:app, %{service_id: service.id})

    event =
      Jason.encode!(%{
        timestamp: 1_790_000_000.5,
        release: "2.3.0",
        server_name: "host-01",
        tags: [["route", "/upload"]],
        exception: %{
          values: [
            %{
              type: "TimeoutError",
              value: "patient 4411 timed out",
              mechanism: %{handled: false},
              stacktrace: %{
                frames: [
                  %{filename: "httpx/_client.py", function: "send", lineno: 914, in_app: false},
                  %{filename: "app/worker.py", function: "run_job", lineno: 212, in_app: true}
                ]
              }
            }
          ]
        }
      })

    envelope =
      Enum.join(
        [
          ~s({"event_id":"9ec79c33ec9942ab8353589fcb2e04dc","dsn":"https://#{app}@dokkit.example/1"}),
          ~s({"type":"session"}),
          ~s({"sid":"x"}),
          ~s({"type":"event","length":#{byte_size(event)}}),
          event,
          ~s({"type":"transaction"}),
          ~s({"spans":[]})
        ],
        "\n"
      )

    conn =
      build_conn()
      |> put_req_header("content-type", "application/x-sentry-envelope")
      |> put_req_header("content-encoding", "gzip")
      |> post("/api/1/envelope/", :zlib.gzip(envelope))

    assert json_response(conn, 200)
    assert [limits] = get_resp_header(conn, "x-sentry-rate-limits")
    assert limits =~ "transaction"

    assert [
             %{
               type: "TimeoutError",
               top: "app/worker.py in run_job",
               handled: false,
               host: "host-01"
             }
           ] =
             Read.errors()

    refute inspect(Repo.all(Dokkit.ErrorEvent)) =~ "4411"

    bad =
      build_conn()
      |> put_req_header("content-type", "application/x-sentry-envelope")
      |> put_req_header("x-sentry-auth", "Sentry sentry_version=7, sentry_key=dka_nope")
      |> post("/api/1/envelope/", envelope)

    assert json_response(bad, 401)
  end

  test "a service set to keep messages keeps them from then on", %{conn: conn} do
    # Its own machine name: tests run side by side and a shared name makes them wait on each other.
    machine = Repo.insert!(%Machine{name: "cellar"})

    service =
      Repo.insert!(%Service{machine_id: machine.id, slug: "portal", name: "Upload portal"})

    {app, _} = Keys.mint(:app, %{service_id: service.id})
    as = put_req_header(build_conn(), "authorization", "Bearer " <> app)

    send = fn ->
      post(as, "/api/v1/errors", %{type: "TimeoutError", message: "upstream took 31 s"})
    end

    send.()
    [%{id: id}] = Read.errors()
    assert Read.error(id).message == nil

    {:ok, view, _} = live(signed_in(conn), "/s/#{service.id}")
    assert render_click(view, "messages") =~ "Stop keeping them"
    send.()
    assert Read.error(id).message == "upstream took 31 s"
    {:ok, _, html} = live(signed_in(conn), "/errors/#{id}")
    assert html =~ "upstream took 31 s"
  end
end
