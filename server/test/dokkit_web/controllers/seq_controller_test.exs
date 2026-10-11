defmodule DokkitWeb.SeqControllerTest do
  use DokkitWeb.ConnCase, async: true
  alias Dokkit.{Keys, Logs, Machine, Repo, Service}

  setup do
    machine = Repo.insert!(%Machine{name: "vault"})

    service =
      Repo.insert!(%Service{machine_id: machine.id, slug: "portal", name: "Upload portal"})

    {app, _} = Keys.mint(:app, %{service_id: service.id})
    %{service: service, app: app}
  end

  defp clef(conn, path, key, lines, header? \\ true) do
    conn =
      if header?,
        do: put_req_header(conn, "x-seq-apikey", key),
        else: conn

    conn
    |> put_req_header("content-type", "application/vnd.serilog.clef")
    |> post(path, Enum.join(lines, "\n"))
  end

  test "Serilog.Sinks.Seq CLEF: key in the header, 201 with the minimum level", %{
    conn: conn,
    app: app,
    service: service
  } do
    now = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

    lines = [
      ~s({"@t":"#{now}","@mt":"Saved {File} in {Elapsed:N0} ms","File":"a.pdf","Elapsed":41,"Application":"Upload"}),
      ~s({"@t":"#{now}","@mt":"Failed {Id}","@l":"Error","@x":"System.IO.IOException: disk","@i":"1a2b3c4d","Id":7}),
      ~s({"@t":"#{now}","@mt":"Starting","@l":"Verbose"})
    ]

    conn = clef(conn, "/api/events/raw?clef", app, lines)
    assert %{"MinimumLevelAccepted" => nil} = json_response(conn, 201)

    rows = Logs.list(service: service.id) |> Map.new(&{&1.msg, &1})

    assert %{level: "info", fields: %{"File" => "a.pdf", "Application" => "Upload"}} =
             rows["Saved a.pdf in 41 ms"]

    assert %{level: "error", fields: %{"exception" => "System.IO.IOException: disk", "Id" => 7}} =
             rows["Failed 7"]

    assert %{level: "trace"} = rows["Starting"]
  end

  test "the key can be the apiKey query value, and /ingest/clef takes the same body", %{
    conn: conn,
    app: app
  } do
    line = ~s({"@t":"#{DateTime.to_iso8601(DateTime.utc_now())}","@m":"by query","@l":"Warning"})

    assert json_response(
             clef(conn, "/api/events/raw?clef&apiKey=#{app}", app, [line], false),
             201
           )

    assert json_response(
             clef(build_conn(), "/ingest/clef", app, [String.replace(line, "by query", "ingest")]),
             201
           )

    assert [%{level: "warn"}] = Logs.list(q: "by query")
    assert [_] = Logs.list(q: "ingest")
  end

  test "winston and pino style short levels and a single JSON event", %{conn: conn, app: app} do
    t = DateTime.to_iso8601(DateTime.utc_now())

    for {level, want} <- [
          {"info", "info"},
          {"warn", "warn"},
          {"Wrn", "warn"},
          {"Err", "error"},
          {"Ftl", "fatal"},
          {"debug", "debug"},
          {"silly", "trace"}
        ] do
      line = ~s({"@t":"#{t}","@m":"lvl #{level}","@l":"#{level}"})
      assert json_response(clef(conn, "/api/events/raw?clef", app, [line]), 201)
      assert [%{level: ^want}] = Logs.list(q: "lvl #{level}")
    end

    one = ~s({"@t":"#{t}","@mt":"One {N}","N":1})

    assert json_response(
             conn
             |> put_req_header("content-type", "application/json")
             |> put_req_header("x-seq-apikey", app)
             |> post("/api/events/raw", one),
             201
           )

    assert [%{msg: "One 1"}] = Logs.list(q: "One 1")
  end

  test "the raw JSON Events form (bunyan, seqlog)", %{conn: conn, app: app} do
    t = DateTime.to_iso8601(DateTime.utc_now())

    body =
      Jason.encode!(%{
        Events: [
          %{
            Timestamp: t,
            Level: "Information",
            MessageTemplate: "Hello {Who}",
            Properties: %{Who: "ann", service: "mine"}
          },
          %{
            Timestamp: t,
            Level: "Error",
            MessageTemplate: "Boom",
            Properties: %{},
            Exception: "Traceback: x"
          }
        ]
      })

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-seq-apikey", app)
      |> post("/api/events/raw", body)

    assert json_response(conn, 201)

    assert [%{msg: "Hello ann", fields: %{"Who" => "ann", "service_name" => "mine"}}] =
             Logs.list(q: "Hello")

    assert [%{level: "error", fields: %{"exception" => "Traceback: x"}}] = Logs.list(q: "Boom")
  end

  test "bad or missing keys and bad bodies answer in Seq's shape", %{conn: conn, app: app} do
    assert %{"Error" => _} =
             json_response(clef(conn, "/api/events/raw?clef", "dka_nope", ["{}"]), 401)

    assert %{"Error" => _} =
             json_response(
               build_conn()
               |> put_req_header("content-type", "text/plain")
               |> post("/api/events/raw?clef", "{}"),
               401
             )

    assert %{"Error" => _} =
             json_response(clef(build_conn(), "/api/events/raw?clef", app, ["not json"]), 400)
  end

  test "the Sentry door and the Seq door do not meet", %{conn: conn, app: app} do
    assert json_response(
             conn
             |> put_req_header("content-type", "application/x-sentry-envelope")
             |> post("/api/events/envelope?sentry_key=#{app}", "{}"),
             200
           )
  end

  test "a request is at most 10,000 events", %{conn: conn, app: app} do
    line = ~s({"@t":"#{DateTime.to_iso8601(DateTime.utc_now())}","@m":"x"})

    assert json_response(
             clef(conn, "/api/events/raw?clef", app, List.duplicate(line, 10_001)),
             413
           )
  end

  # The shapes seqlog 0.4.3 sent when its handler was run against a capture server: the raw form
  # to /api/events/raw with a space in the time, the CLEF form to /ingest/clef joined by CRLF.
  @props %{
    "MachineName" => "host1",
    "ProcessId" => 15148,
    "LoggerName" => "upload.portal",
    "ThreadId" => 56116,
    "ThreadName" => "MainThread"
  }
  @trace "Traceback (most recent call last):\n  File \"capture.py\", line 41, in <module>\n    1 / 0\nZeroDivisionError: division by zero"

  defp seqlog_time(sep) do
    DateTime.utc_now()
    |> DateTime.add(-30)
    |> Calendar.strftime("%Y-%m-%d#{sep}%H:%M:%S.017154+00:00")
  end

  test "seqlog's JSON form, as it sends it", %{conn: conn, app: app, service: service} do
    t = seqlog_time(" ")

    body =
      Jason.encode!(%{
        "Events" => [
          %{
            "Timestamp" => t,
            "Level" => "INFO",
            "MessageTemplate" => "Saved a.pdf in 41 ms",
            "Properties" => Map.merge(@props, %{"0" => "a.pdf", "1" => 41})
          },
          %{
            "Timestamp" => t,
            "Level" => "ERROR",
            "MessageTemplate" => "Divide failed for {user}",
            "Properties" => @props,
            "Exception" => @trace
          }
        ]
      })

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-seq-apikey", app)
      |> post("/api/events/raw", body)

    assert json_response(conn, 201)

    assert [
             %{
               level: "error",
               fields: %{"exception" => "Traceback" <> _, "LoggerName" => "upload.portal"}
             },
             %{level: "info", msg: "Saved a.pdf in 41 ms"}
           ] = Logs.list(service: service.id)
  end

  test "seqlog's CLEF form, as it sends it", %{conn: conn, app: app, service: service} do
    t = seqlog_time("T")

    body =
      Enum.map_join(
        [
          Map.merge(@props, %{
            "@t" => t,
            "@l" => "INFO",
            "@mt" => "Saved a.pdf in 41 ms",
            "@r" => ["a.pdf", "41"]
          }),
          Map.merge(@props, %{
            "@t" => t,
            "@l" => "ERROR",
            "@mt" => "Divide failed for {user}",
            "@r" => [],
            "@x" => @trace
          })
        ],
        "\r\n",
        &Jason.encode!/1
      )

    conn =
      conn
      |> put_req_header("content-type", "application/vnd.serilog.clef")
      |> put_req_header("x-seq-apikey", app)
      |> post("/ingest/clef", body)

    assert json_response(conn, 201)

    assert [
             %{
               level: "error",
               msg: "Divide failed for {user}",
               fields: %{"exception" => "Traceback" <> _}
             },
             %{level: "info", msg: "Saved a.pdf in 41 ms"}
           ] = Logs.list(service: service.id)
  end
end
