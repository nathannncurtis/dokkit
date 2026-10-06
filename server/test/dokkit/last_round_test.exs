defmodule Dokkit.LastRoundTest do
  use DokkitWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Dokkit.{
    Alert,
    Alerts,
    Check,
    Estate,
    Issue,
    Issues,
    Keys,
    Machine,
    Numbers,
    Repo,
    Service
  }

  @noon ~U[2026-01-10 12:00:00.000000Z]
  @late ~U[2026-01-10 23:30:00.000000Z]

  setup do
    Alerts.save(%{
      "pagerduty_key" => "K",
      "degraded" => "push",
      "disk_limit" => "90",
      "ntfy_url" => "https://ntfy.example/topic",
      "ntfy_token" => "SECRET-NTFY",
      "night_from" => "22",
      "night_to" => "7"
    })

    me = self()

    Req.Test.stub(Alerts, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      action = if conn.host =~ "pagerduty", do: Jason.decode!(body)["event_action"], else: "push"
      send(me, {:req, conn.host, action})
      Plug.Conn.send_resp(conn, 202, "{}")
    end)

    :ok
  end

  defp job(slug, attrs \\ []) do
    m =
      Repo.insert!(%Machine{
        name: "l-" <> slug,
        kind: :enrolled,
        last_seen_at: DateTime.utc_now()
      })

    s =
      Repo.insert!(
        struct!(
          Service,
          [machine_id: m.id, slug: slug, name: "Job " <> slug, kind: :job] ++ attrs
        )
      )

    c = Repo.insert!(%Check{service_id: s.id, name: slug, type: :job, fail_after: 1})
    {m, s, c}
  end

  defp rec(c, state, minutes, opts \\ []) do
    at = DateTime.add(@noon, minutes * 60)
    Issues.record(Repo.reload!(c), state, [at: at, now: at] ++ opts)
  end

  defp send_all(c, state, minutes, opts \\ []) do
    rec(c, state, minutes, opts)
    Alerts.deliver_pending()
  end

  defp events do
    Stream.repeatedly(fn ->
      receive do
        {:req, host, action} -> {host, action}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  defp count(events, action), do: Enum.count(events, &(elem(&1, 1) == action))
  defp issues(c), do: Repo.all(from i in Issue, where: i.check_id == ^c.id, order_by: i.since)
  defp alert(i), do: Repo.get_by(Alert, issue_id: i.id)

  defp open_issue(c),
    do: Repo.one!(from i in Issue, where: i.check_id == ^c.id and is_nil(i.closed_at))

  defp call(token, name, args) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/mcp", %{
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: %{name: name, arguments: args}
    })
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp api(method, path, token, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> dispatch(@endpoint, method, "/api/v1" <> path, body)
  end

  defp admin, do: elem(Keys.mint(:user, %{scopes: ~w(read act admin), label: "x"}), 0)

  describe "a reopened failure always has a live alert" do
    test "down, one degraded result, down again inside 30 minutes pages again" do
      {_, _, c} = job("a1")
      send_all(c, :down, 0)
      send_all(c, :degraded, 1)
      send_all(c, :down, 2)

      ev = events()
      assert count(ev, "trigger") == 2 and count(ev, "resolve") == 1 and count(ev, "push") == 1
      assert %Issue{state: :down, count: 2} = open_issue(c)
      assert alert(open_issue(c)).status == :sent
    end

    test "down, ok, down inside 30 minutes pages again" do
      {_, _, c} = job("a2")
      send_all(c, :down, 0)
      send_all(c, :ok, 1)
      send_all(c, :down, 2)
      ev = events()
      assert count(ev, "trigger") == 2 and count(ev, "resolve") == 1
      assert alert(open_issue(c)).status == :sent
    end

    test "down twice in a row is one page" do
      {_, _, c} = job("a3")
      send_all(c, :down, 0)
      send_all(c, :down, 1)
      assert count(events(), "trigger") == 1
    end

    test "soon, down, soon: the warning is not pushed again, the failure pages again" do
      {_, _, c} = job("a4")
      send_all(c, :degraded, 0, soon: true)
      send_all(c, :down, 1)
      send_all(c, :degraded, 2, soon: true)
      ev = events()
      assert count(ev, "push") == 1 and count(ev, "trigger") == 1 and count(ev, "resolve") == 1
      assert %Issue{soon: true} = soon = open_issue(c)
      assert alert(soon).status == :sent

      send_all(c, :down, 3)
      ev = events()
      assert count(ev, "trigger") == 1 and count(ev, "push") == 0
      assert alert(open_issue(c)).status == :sent
    end

    test "flapping every minute for ten minutes: five pages when each resolve went out" do
      {_, _, c} = job("a5")

      for minute <- 0..9, do: send_all(c, if(rem(minute, 2) == 0, do: :down, else: :ok), minute)

      ev = events()
      assert count(ev, "trigger") == 5
      assert count(ev, "resolve") == 5
      assert length(issues(c)) == 1
    end

    test "flapping faster than alerts are sent pages nobody and resolves nothing" do
      {_, _, c} = job("a6")
      for minute <- 0..9, do: rec(c, if(rem(minute, 2) == 0, do: :down, else: :ok), minute)
      assert Alerts.deliver_pending() == 0
      assert events() == []
    end
  end

  describe "a snooze, a seen mark, notes and the number follow a change of state" do
    test "down to degraded keeps the snooze, the seen mark, the notes and the number, and says nothing" do
      {_, _, c} = job("b1")
      rec(c, :down, 0)
      down = open_issue(c)
      Issues.snooze(down.id, 86_400)
      Issues.acknowledge(down.id)
      Issues.note(down.id, "known", "me")
      rec(c, :degraded, 1)

      [old, heir] = issues(c)
      heir = Repo.reload!(heir)
      assert old.id == down.id and old.closed_at
      assert heir.number == down.number and Repo.reload!(old).number != down.number
      assert heir.snoozed_until && heir.acknowledged_at
      assert [%{"text" => "known"}] = heir.notes
      assert alert(heir) == nil
      assert Issues.open_list() |> Enum.all?(&(&1.id != heir.id))
    end

    test "degraded to down is an escalation: it keeps the number and notes, loses the snooze and alerts" do
      {_, _, c} = job("b2")
      rec(c, :degraded, 0)
      warn = open_issue(c)
      Issues.snooze(warn.id, 86_400)
      Issues.acknowledge(warn.id)
      Issues.note(warn.id, "known", "me")
      rec(c, :down, 1)

      down = open_issue(c)
      assert down.number == warn.number
      assert [%{"text" => "known"}] = down.notes
      assert is_nil(down.snoozed_until)
      assert is_nil(down.acknowledged_at)
      assert alert(down).status == :pending
    end

    test "the number a person saw never appears twice" do
      {_, _, c} = job("b3")
      rec(c, :degraded, 0)
      rec(c, :down, 1)
      numbers = Enum.map(issues(c), & &1.number)
      assert numbers == Enum.uniq(numbers)
    end
  end

  describe "the night is decided by the server's clock" do
    test "a report stamped at night is not held when it arrives by day, and the reverse" do
      {_, _, a} = job("c1", night: false)
      {_, _, b} = job("c2", night: false)
      Issues.record(a, :down, at: @late, now: @noon)
      Issues.record(b, :down, at: @noon, now: @late)
      assert alert(open_issue(a)).status == :pending
      assert alert(open_issue(b)).status == :held
    end

    test "turning night alerts on does not send a held alert of a snoozed or seen issue" do
      {_, s, c} = job("c3", night: false)
      {_, s2, c2} = job("c4", night: false)
      Issues.record(c, :down, at: @late, now: @late)
      Issues.record(c2, :down, at: @late, now: @late)
      Issues.snooze(open_issue(c).id, 86_400)
      Issues.acknowledge(open_issue(c2).id)
      Estate.set_routing(s, %{"night" => true})
      Estate.set_routing(s2, %{"night" => true})
      assert alert(open_issue(c)).status == :held
      assert alert(open_issue(c2)).status == :held
    end

    test "held until is said in the night's own offset" do
      assert Alerts.night_ends() == "07:00 UTC"
      Alerts.save(%{"night_offset" => "2"})
      assert Alerts.night_ends() == "07:00 UTC+2"
      Alerts.save(%{"night_offset" => "-6", "night_to" => "6"})
      assert Alerts.night_ends() == "06:00 UTC-6"
    end

    test "the inbox says when a held alert goes out, in the night's offset", %{conn: conn} do
      Alerts.save(%{"night_offset" => "2"})
      {_, _, c} = job("c5", night: false)
      Issues.record(c, :down, at: @late, now: @late)
      {:ok, _, html} = live(signed_in(conn), "/")
      assert html =~ "Held until 07:00 UTC+2"
    end
  end

  describe "a secret goes only to the host it was given for" do
    test "changing the ntfy address without sending the token clears it and says so" do
      assert {:ok, config, note} = Alerts.update(%{"ntfy_url" => "https://other.example/x"})
      assert config["ntfy_token"] == ""
      assert note =~ "ntfy_token was cleared"

      Alerts.update(%{"ntfy_url" => "https://other.example/x", "ntfy_token" => "NEW"})

      assert {:ok, config, nil} =
               Alerts.update(%{"ntfy_url" => "https://third.example/x", "ntfy_token" => "NEW"})

      assert config["ntfy_token"] == "NEW"

      assert {:ok, config, nil} =
               Alerts.update(%{"ntfy_url" => "https://third.example/other-path"})

      assert config["ntfy_token"] == "NEW"
    end

    test "the stored token is never sent to the new host" do
      Alerts.update(%{"ntfy_url" => "https://other.example/x"})
      me = self()

      Req.Test.stub(Alerts, fn conn ->
        send(me, {:auth, conn.host, Plug.Conn.get_req_header(conn, "authorization")})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert Alerts.test("push") == :ok
      assert_received {:auth, "other.example", []}
    end

    test "changing the mail server clears the password" do
      Alerts.update(%{"smtp_host" => "mail.example", "smtp_password" => "PW"})
      assert {:ok, config, note} = Alerts.update(%{"smtp_host" => "relay.example"})
      assert config["smtp_password"] == "" and note =~ "smtp_password was cleared"
    end

    test "the API says so, and an empty string clears a secret" do
      t = admin()
      body = json_response(api(:put, "/alerts", t, %{ntfy_url: "https://other.example/x"}), 200)
      assert body["note"] =~ "ntfy_token was cleared" and body["ntfy_token"] == "not set"

      assert json_response(api(:put, "/alerts", t, %{down: "push"}), 200)["pagerduty_key"] ==
               "set"

      assert json_response(api(:put, "/alerts", t, %{pagerduty_key: ""}), 200)["pagerduty_key"] ==
               "not set"
    end

    test "the interface says so too", %{conn: conn} do
      {:ok, view, _} = live(signed_in(conn), "/alerts")

      html =
        view
        |> form("#alerts-form", alerts: %{ntfy_url: "https://other.example/x"})
        |> render_submit()

      assert html =~ "ntfy_token was cleared"
      assert Alerts.config()["ntfy_token"] == ""
    end

    test "the interface keeps a secret left empty and clears one that is ticked", %{conn: conn} do
      {:ok, view, _} = live(signed_in(conn), "/alerts")
      view |> form("#alerts-form", alerts: %{down: "push"}) |> render_submit()
      assert Alerts.config()["pagerduty_key"] == "K"

      view
      |> form("#alerts-form", alerts: %{clear_pagerduty_key: "true"})
      |> render_submit()

      assert Alerts.config()["pagerduty_key"] == ""
    end
  end

  describe "where an alert may be sent" do
    setup do
      on_exit(fn -> System.delete_env("DOKKIT_ALLOW_LOCAL_ALERTS") end)
    end

    test "loopback, link-local and unspecified are refused, the private network is not" do
      for url <-
            ~w(https://127.0.0.1/x https://169.254.169.254/x https://localhost/x https://0.0.0.0/x) do
        assert {:error, _} = Alerts.check_url(url), url
      end

      for url <- ~w(https://10.0.0.5/x https://192.168.1.1:8443/ https://172.16.0.9/x) do
        assert Alerts.check_url(url) == :ok, url
      end
    end

    test "DOKKIT_ALLOW_LOCAL_ALERTS=1 allows them" do
      System.put_env("DOKKIT_ALLOW_LOCAL_ALERTS", "1")
      assert Alerts.check_url("https://127.0.0.1/x") == :ok
      assert {:ok, _, _} = Alerts.update(%{"smtp_host" => "127.0.0.1", "smtp_port" => "25"})
    end

    test "the mail server is checked and only the mail ports are used" do
      assert {:error, why} = Alerts.update(%{"smtp_host" => "127.0.0.1", "smtp_port" => "587"})
      assert why =~ "smtp_host"

      assert {:error, "smtp_port is one of 25, 465, 587, 2525."} =
               Alerts.update(%{"smtp_host" => "10.0.0.5", "smtp_port" => "5432"})

      for port <- ~w(25 465 587 2525),
          do:
            assert({:ok, _, _} = Alerts.update(%{"smtp_host" => "10.0.0.5", "smtp_port" => port}))
    end

    test "the mail connection goes to the address that was checked, with no other lookup" do
      opts = Dokkit.Mail.smtp_options("mail.example", %{"smtp_port" => "587"}, [{10, 0, 0, 5}])
      assert opts[:relay] == ~c"10.0.0.5" and opts[:no_mx_lookups] == true
      assert opts[:tls_options][:server_name_indication] == ~c"mail.example"
    end

    test "a failed test says one fixed thing, never what the far end said" do
      Req.Test.stub(Alerts, fn conn -> Plug.Conn.send_resp(conn, 500, "BANNER-XYZ 220 secret") end)

      assert {:error, text} = Alerts.test("push")
      refute text =~ "BANNER" or text =~ "500" or text =~ "ntfy.example"

      Req.Test.stub(Alerts, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, ^text} = Alerts.test("push")

      t = admin()

      assert %{"error" => %{"message" => ^text}} =
               json_response(api(:post, "/alerts/test", t, %{channel: "push"}), 422)
    end

    test "the test call is rate limited for each token, in the API and the MCP" do
      t = admin()

      for _ <- 1..4,
          do:
            assert(
              %{"ok" => true} =
                json_response(api(:post, "/alerts/test", t, %{channel: "page"}), 200)
            )

      assert %{"error" => %{"code" => "slow_down"}} =
               json_response(api(:post, "/alerts/test", t, %{channel: "page"}), 422)
    end
  end

  describe "the MCP" do
    test "null for an optional argument is left out, and a whole float is an integer" do
      {_, s, _} = job("m1")
      t = admin()
      refute call(t, "hold", %{id: s.id, version: nil})["isError"]
      refute call(t, "routing", %{id: s.id, down: nil, degraded: "push"})["isError"]
      refute call(t, "series", %{id: s.id, points: 5.0})["isError"]
      refute call(t, "find", %{q: "m1", machine: nil})["isError"]
      assert call(t, "series", %{id: s.id, points: 5.5})["isError"]
    end

    test "test_alert is rate limited per token" do
      t = admin()
      for _ <- 1..4, do: refute(call(t, "test_alert", %{channel: "page"})["isError"])

      assert %{"isError" => true, "content" => [%{"text" => "Too many tests." <> _}]} =
               call(t, "test_alert", %{channel: "page"})
    end
  end

  describe "rules and job timing" do
    test "a rule with a null or unknown channel, or a machine that is not text, is a 422" do
      t = admin()
      [r] = Alerts.add_rule(%{"kind" => "job", "channel" => "page"})

      for body <- [%{channel: nil}, %{channel: "bogus"}, %{machine: 5}, %{kind: "x"}] do
        assert json_response(api(:put, "/rules/#{r["id"]}", t, body), 422)["error"]["code"] ==
                 "bad_rule"
      end

      assert json_response(api(:put, "/rules/#{r["id"]}", t, %{channel: ""}), 200)["channel"] ==
               "none"

      assert json_response(api(:post, "/rules", t, %{channel: "nope"}), 422)
    end

    test "job timing merges: a field left out stays, an empty one clears" do
      {_, s, _} = job("t1")
      t = admin()
      api(:put, "/jobs/#{s.id}/timing", t, %{grace: "30m", max_runtime: "1h"})
      api(:put, "/jobs/#{s.id}/timing", t, %{grace: "45m"})
      check = Repo.get_by!(Check, service_id: s.id)
      assert %{"grace" => "45m", "max_runtime" => "1h"} = check.config
      api(:put, "/jobs/#{s.id}/timing", t, %{max_runtime: ""})
      assert %{"grace" => "45m"} = config = Repo.reload!(check).config
      refute config["max_runtime"]
    end
  end

  describe "smaller things" do
    test "fine counts only services that have reported fine" do
      before = Issues.fine().services
      {_, _, c} = job("f1")
      assert Issues.fine().services == before
      Issues.record(c, :ok)
      assert Issues.fine().services == before + 1
    end

    test "the shell asks the database three times at most" do
      for n <- 1..3, do: Issues.record(elem(job("q#{n}"), 2), :down)
      ref = make_ref()
      me = self()
      :telemetry.attach(ref, [:dokkit, :repo, :query], fn _, _, _, _ -> send(me, :q) end, nil)
      machines = Issues.machines()
      open = Issues.open_count()
      :telemetry.detach(ref)

      queries =
        Stream.repeatedly(fn ->
          receive do
            :q -> 1
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> length()

      IO.puts("shell queries: #{queries}")
      assert queries <= 3
      assert open == 3 and Enum.sum(Enum.map(machines, & &1.attention)) == 3
    end

    test "alert secrets and addresses are filtered from the logs" do
      names =
        ~w(pagerduty_key ntfy_token pushover_token pushover_user smtp_password smtp_user ntfy_url webhook_url heartbeat_url)

      params = Map.new(names, &{&1, "x"})

      assert Phoenix.Logger.filter_values(%{"params" => %{"arguments" => params}}) == %{
               "params" => %{"arguments" => Map.new(names, &{&1, "[FILTERED]"})}
             }
    end

    test "full in days is cleared when the limit is blanked or the readings stop" do
      m = Repo.insert!(%Machine{name: "l-full", kind: :enrolled})
      now = DateTime.utc_now()

      for {v, i} <- Enum.with_index([90.5, 90.51, 90.52, 90.53, 90.54, 90.55, 90.56, 90.57]),
          do:
            Numbers.record(
              m.id,
              nil,
              "disk.used_percent.D",
              v,
              DateTime.add(now, -(7 - i) * 86_400)
            )

      Numbers.record(m.id, nil, "disk.used_percent.D", 91, now)
      Numbers.forecast(now)

      check = fn ->
        Repo.one!(
          from c in Check,
            join: s in assoc(c, :service),
            where: s.machine_id == ^m.id and c.name == "disk.used_percent.D"
        )
      end

      Repo.update!(
        Ecto.Changeset.change(check.(),
          config: %{"full_in_days" => 20},
          note: "It is 91 percent full."
        )
      )

      Alerts.save(%{"disk_limit" => ""})
      Numbers.forecast(now)
      refute check.().config["full_in_days"]

      Alerts.save(%{"disk_limit" => "90"})
      Repo.update!(Ecto.Changeset.change(check.(), config: %{"full_in_days" => 20}))
      Numbers.forecast(DateTime.add(now, 30 * 86_400))
      refute check.().config["full_in_days"]
    end

    test "one app key cannot fill the seen machines of the others" do
      {_, s1, _} = job("k1")
      {_, s2, _} = job("k2")
      {k1, key1} = Keys.mint(:app, %{service_id: s1.id})
      {k2, _} = Keys.mint(:app, %{service_id: s2.id})

      for batch <- 1..5 do
        lines =
          for n <- 1..50,
              do: %{
                type: "log",
                service: "k1",
                host: "flood-#{batch}-#{n}",
                level: "info",
                message: "hi"
              }

        report(k1, lines)
      end

      assert Repo.aggregate(from(m in Machine, where: m.seen_by == ^key1.id), :count) == 200
      report(k2, [%{type: "log", service: "k2", host: "other-pc", level: "info", message: "hi"}])
      assert Repo.get_by(Machine, name: "other-pc")
    end

    test "the estate keeps its own 500 as a backstop" do
      {_, s2, _} = job("k3")
      {k2, _} = Keys.mint(:app, %{service_id: s2.id})
      now = DateTime.utc_now()

      rows =
        for n <- 1..500,
            do: %{
              id: Ecto.UUID.generate(),
              name: "old-#{n}",
              kind: :seen,
              last_seen_at: now,
              inserted_at: now,
              updated_at: now
            }

      Repo.insert_all(Machine, rows)
      report(k2, [%{type: "log", service: "k3", host: "late-pc", level: "info", message: "hi"}])
      assert Repo.get_by(Machine, name: "late-pc") == nil
    end
  end

  describe "what the API holds at admin an owner does in the interface" do
    defp member(conn) do
      user =
        Repo.insert!(%Dokkit.User{
          name: "mem-#{System.unique_integer([:positive])}",
          password_hash: "-",
          role: :member
        })

      Plug.Test.init_test_session(conn, %{
        "user_id" => user.id,
        "signed_at" => Dokkit.Accounts.stamp()
      })
    end

    test "a member is told an owner adds jobs, and none is added", %{conn: conn} do
      {:ok, view, html} = live(member(conn), "/jobs/new")
      assert html =~ "An owner adds jobs."

      view
      |> form("#job-form", job: %{name: "nightly", machine: "box-1"})
      |> render_submit()

      assert render(view) =~ "An owner adds jobs."
      assert Repo.aggregate(from(s in Service, where: s.slug == "nightly"), :count) == 0
    end

    test "a member cannot allow restarts, and the page says an owner does", %{conn: conn} do
      {_, s, c} = job("r1")
      Repo.update!(Ecto.Changeset.change(c, type: :systemd))
      {:ok, view, html} = live(member(conn), "/s/#{s.id}")
      assert html =~ "An owner changes this."
      render_click(view, "restart", %{})
      refute Repo.reload!(s).restart

      {:ok, view, _} = live(signed_in(conn), "/s/#{s.id}")
      render_click(view, "restart", %{})
      assert Repo.reload!(s).restart
    end
  end
end
