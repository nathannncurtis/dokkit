defmodule Dokkit.ImessageTest do
  use DokkitWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  alias Dokkit.{Alert, Alerts, Intake, Issues, Keys, Machine, Repo, Service, WorkRun}

  setup do
    mac = Repo.insert!(%Machine{name: "mac-mini", kind: :enrolled, os: "darwin"})
    other = Repo.insert!(%Machine{name: "mac-air", kind: :enrolled, os: "darwin"})
    vault = Repo.insert!(%Machine{name: "vault", kind: :enrolled, os: "linux"})
    {mac_key, _} = Keys.mint(:machine, %{machine_id: mac.id})
    {other_key, _} = Keys.mint(:machine, %{machine_id: other.id})

    service =
      Repo.insert!(%Service{
        machine_id: vault.id,
        slug: "backup",
        name: "Nightly backup",
        kind: :job
      })

    {_, app} = Keys.mint(:app, %{service_id: service.id})

    Alerts.save(%{
      "down" => "imessage",
      "imessage_machine" => mac.id,
      "imessage_to" => "+15555550100, someone@example.com"
    })

    Req.Test.stub(Alerts, fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end)

    %{mac: mac, mac_key: mac_key, other_key: other_key, vault: vault, app: app}
  end

  defp as(key), do: put_req_header(build_conn(), "authorization", "Bearer " <> key)
  defp work(key), do: get(as(key), "/api/v1/work?wait=0")

  defp result(key, run, body),
    do: json_response(post(as(key), "/api/v1/work/#{run}/result", body), 200)

  defp output(key, run, text),
    do:
      post(
        put_req_header(as(key), "content-type", "text/plain"),
        "/api/v1/work/#{run}/output",
        text
      )

  defp open_alert(app) do
    Intake.ping(app, "backup", "fail", nil, "disk full")
    assert Alerts.deliver_pending() == 1
    [%{alerts: [alert]}] = Issues.open_list()
    alert
  end

  defp status(alert), do: Repo.get!(Alert, alert.id)
  defp ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60)

  defp retry do
    Repo.update_all(Alert, set: [updated_at: ago(2)])
    Alerts.deliver_pending()
  end

  test "the chosen Mac is handed exactly the contract, and no other machine is", ctx do
    alert = open_alert(ctx.app)
    assert %{status: :sending} = status(alert)

    assert response(work(ctx.other_key), 204)

    assert %{
             "run" => run,
             "task" => "dokkit:imessage",
             "to" => ["+15555550100", "someone@example.com"],
             "text" => "Nightly backup failed (vault, DOK-" <> _ = text
           } = body = json_response(work(ctx.mac_key), 200)

    assert Map.keys(body) |> Enum.sort() == ~w(run task text to)
    assert text =~ ")"
    assert response(work(ctx.mac_key), 204)

    output(ctx.mac_key, run, "sent to +15555550100\nsent to someone@example.com\n")
    result(ctx.mac_key, run, %{exit_code: 0, duration_ms: 900})
    assert %{status: :sent, error: nil} = status(alert)
  end

  test "an answer of exit code 1 fails the alert with the program's lines", ctx do
    alert = open_alert(ctx.app)
    %{"run" => run} = json_response(work(ctx.mac_key), 200)

    output(
      ctx.mac_key,
      run,
      "sent to +15555550100\nnot sent to someone@example.com: not signed in\n"
    )

    result(ctx.mac_key, run, %{exit_code: 1, duration_ms: 50})

    assert %{status: :failed, error: error} = status(alert)
    assert error == "sent to +15555550100; not sent to someone@example.com: not signed in"
  end

  test "a refusal fails the alert with its reason", ctx do
    alert = open_alert(ctx.app)
    %{"run" => run} = json_response(work(ctx.mac_key), 200)
    result(ctx.mac_key, run, %{refused: "iMessage is not switched on. Run dokkit imessage on."})

    assert %{status: :failed, error: "iMessage is not switched on." <> _} = status(alert)
  end

  test "a failed answer is tried again with a new run", ctx do
    alert = open_alert(ctx.app)
    %{"run" => run} = json_response(work(ctx.mac_key), 200)
    result(ctx.mac_key, run, %{exit_code: 1})
    assert %{status: :failed, error: "The Mac answered with exit code 1."} = status(alert)

    assert retry() == 1
    assert %{status: :sending} = status(alert)
    assert %{"run" => again} = json_response(work(ctx.mac_key), 200)
    assert again != run
    result(ctx.mac_key, again, %{exit_code: 0})
    assert %{status: :sent} = status(alert)
  end

  test "five minutes without an answer fails it, and a late success still marks it sent", ctx do
    alert = open_alert(ctx.app)
    Repo.update_all(WorkRun, set: [inserted_at: ago(4)])
    assert Alerts.settle() == 0
    assert %{status: :sending} = status(alert)

    Repo.update_all(WorkRun, set: [inserted_at: ago(6)])
    assert Alerts.settle() == 1

    assert %{
             status: :failed,
             error: "The Mac that sends iMessages, mac-mini, did not pick it up."
           } =
             status(alert)

    # The retry waits on the same run: no second message is queued.
    retry()
    assert %{status: :failed} = status(alert)
    assert Repo.aggregate(WorkRun, :count) == 1

    # The Mac wakes up, takes the one run and answers.
    assert %{"run" => run} = json_response(work(ctx.mac_key), 200)
    assert response(work(ctx.mac_key), 204)
    result(ctx.mac_key, run, %{exit_code: 0})
    assert %{status: :sent, error: nil} = status(alert)
    assert Repo.aggregate(WorkRun, :count) == 1
  end

  test "a close sends nothing", ctx do
    alert = open_alert(ctx.app)
    %{"run" => run} = json_response(work(ctx.mac_key), 200)
    result(ctx.mac_key, run, %{exit_code: 0})
    Intake.ping(ctx.app, "backup", "ok", nil, "")
    Alerts.deliver_pending()
    assert response(work(ctx.mac_key), 204)
    assert %{status: :closed} = status(alert)
    assert Repo.aggregate(WorkRun, :count) == 1
  end

  test "with no Mac chosen it fails and says why", ctx do
    Alerts.update(%{"imessage_machine" => ""})
    alert = open_alert(ctx.app)
    assert %{status: :failed, error: "iMessage has no Mac chosen yet."} = status(alert)
    assert response(work(ctx.mac_key), 204)
  end

  test "the test send goes the same way and shows the answer", ctx do
    test = Elixir.Task.async(fn -> Alerts.test("imessage") end)

    run =
      Enum.find_value(1..50, fn _ ->
        case work(ctx.mac_key) do
          %{status: 200} = conn -> json_response(conn, 200)
          _ -> Process.sleep(100) && nil
        end
      end)

    assert run["to"] == ["+15555550100", "someone@example.com"]
    result(ctx.mac_key, run["run"], %{refused: "No."})
    assert Elixir.Task.await(test) == {:error, "No."}
  end

  test "a test nobody picks up is withdrawn", ctx do
    Application.put_env(:dokkit, :imessage_test_wait, 0)
    on_exit(fn -> Application.delete_env(:dokkit, :imessage_test_wait) end)

    assert Alerts.test("imessage") ==
             {:error, "The Mac that sends iMessages, mac-mini, did not pick it up."}

    assert response(work(ctx.mac_key), 204)
  end

  describe "settings" do
    test "the Mac must be an enrolled Mac", ctx do
      assert {:error, "iMessage goes out through a Mac. vault is not one."} =
               Alerts.update(%{"imessage_machine" => ctx.vault.id})

      assert {:error, "iMessage goes out through a Mac. That machine is not one."} =
               Alerts.update(%{"imessage_machine" => "nope"})

      seen = Repo.insert!(%Machine{name: "seen-mac", kind: :seen, os: "darwin"})

      assert {:error, "iMessage goes out through a Mac. seen-mac" <> _} =
               Alerts.update(%{"imessage_machine" => seen.id})

      assert {:ok, %{"imessage_machine" => id}, _} =
               Alerts.update(%{"imessage_machine" => ctx.mac.id})

      assert id == ctx.mac.id
    end

    test "recipients look like phone numbers or email addresses" do
      assert {:error, "imessage_to: nobody is not a phone number or an email address."} =
               Alerts.update(%{"imessage_to" => "+15555550100, nobody"})

      assert {:ok, _, _} = Alerts.update(%{"imessage_to" => "+1 (555) 555-0100,a@b.example"})

      assert {:error, "sms_to: a@b.example is not a phone number."} =
               Alerts.update(%{"sms_to" => "a@b.example"})

      assert {:error, "twilio_sid" <> _} = Alerts.update(%{"twilio_sid" => "../x"})
    end

    test "the Twilio token is never returned" do
      Alerts.update(%{
        "twilio_sid" => "ACabc",
        "twilio_token" => "SECRET",
        "sms_to" => "+15555550101"
      })

      view = Alerts.view()
      assert view["twilio_token"] == "set" and view["twilio_sid"] == "set"
      assert view["sms_to"] == "+15555550101"
    end
  end

  describe "SMS" do
    setup do
      Alerts.save(%{
        "down" => "sms",
        "twilio_sid" => "ACabc123",
        "twilio_token" => "tok",
        "twilio_from" => "+15555550100",
        "sms_to" => "+15555550101, +1 (555) 555-0102"
      })

      test = self()

      Req.Test.stub(Alerts, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:twilio, conn.host, conn.request_path, conn.req_headers, body})
        Plug.Conn.send_resp(conn, 201, "{}")
      end)

      :ok
    end

    test "one request to Twilio for each recipient" do
      assert Alerts.test("sms") == :ok

      for to <- ["%2B15555550101", "%2B15555550102"] do
        assert_received {:twilio, "api.twilio.com", path, headers, body}
        assert path == "/2010-04-01/Accounts/ACabc123/Messages.json"
        assert {"authorization", "Basic " <> auth} = List.keyfind(headers, "authorization", 0)
        assert Base.decode64!(auth) == "ACabc123:tok"
        assert body =~ "To=#{to}"
        assert body =~ "From=%2B15555550100"
        assert body =~ "Body=A+test+from+Dokkit+%28dokkit%2C+DOK-0%29"
      end

      refute_received {:twilio, _, _, _, _}
    end

    test "an alert goes by SMS and Twilio's message is the reason when it fails", ctx do
      alert = open_alert(ctx.app)
      assert %{status: :sent} = status(alert)

      Req.Test.stub(Alerts, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"code":21211,"message":"The 'To' number is not valid."}))
      end)

      assert Alerts.test("sms") == {:error, "The 'To' number is not valid."}
    end

    test "an answer without a message is the usual fixed reason" do
      Req.Test.stub(Alerts, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      assert {:error, "Dokkit could not deliver it there." <> _} = Alerts.test("sms")
    end

    test "missing settings are said" do
      Alerts.save(%{"twilio_token" => ""})
      assert Alerts.test("sms") == {:error, "SMS needs a Twilio account SID and auth token."}
    end
  end

  describe "the text channel became SMS" do
    test "stored choices change and text_to is dropped" do
      Code.require_file("priv/repo/migrations/20261007001500_text_becomes_sms.exs")

      machine = Repo.insert!(%Machine{name: "m"})

      Repo.insert!(%Service{
        machine_id: machine.id,
        slug: "a",
        name: "A",
        route_down: "text",
        route_degraded: "push"
      })

      Repo.insert!(%Service{
        machine_id: machine.id,
        slug: "b",
        name: "B",
        route_down: "page",
        route_degraded: "text"
      })

      Alerts.save(%{"email_to" => "a@b.example"})

      Repo.insert!(
        %Dokkit.Setting{
          key: "alerts",
          value:
            Map.merge(Alerts.config(), %{
              "down" => "text",
              "degraded" => "text",
              "text_to" => "5551234567@carrier.example"
            })
        },
        on_conflict: :replace_all,
        conflict_target: :key
      )

      Repo.insert!(
        %Dokkit.Setting{
          key: "rules",
          value: %{
            "list" => [
              %{"id" => "1", "channel" => "text", "on" => true},
              %{"id" => "2", "channel" => "page", "on" => true},
              %{"id" => "3", "channel" => "text", "on" => false}
            ]
          }
        },
        on_conflict: :replace_all,
        conflict_target: :key
      )

      migration = Dokkit.Repo.Migrations.TextBecomesSms
      for sql <- apply(migration, :statements, []), do: Repo.query!(sql)

      assert Repo.get_by!(Service, slug: "a") |> Map.take([:route_down, :route_degraded]) ==
               %{route_down: "sms", route_degraded: "push"}

      assert Repo.get_by!(Service, slug: "b") |> Map.take([:route_down, :route_degraded]) ==
               %{route_down: "page", route_degraded: "sms"}

      config = Alerts.config()
      assert config["down"] == "sms" and config["degraded"] == "sms"
      assert config["email_to"] == "a@b.example"
      refute Map.has_key?(config, "text_to")

      assert for(r <- Alerts.rules(), do: {r["id"], r["channel"]}) ==
               [{"1", "sms"}, {"2", "page"}, {"3", "sms"}]
    end

    test "an alert recorded as text still reads as Texted" do
      assert Alerts.sent_word("text") == "Texted"
      assert Alerts.sent_word("sms") == "Sent an SMS"
      assert Alerts.sent_word("imessage") == "Sent an iMessage"
      refute Alerts.sends?("text")
    end
  end

  describe "the Alerts page" do
    test "says plainly when no Mac is enrolled", %{conn: conn} do
      Repo.delete_all(from m in Machine, where: m.os == "darwin")
      Alerts.save(%{"imessage_machine" => ""})
      {:ok, _, html} = live(signed_in(conn), "/alerts")

      assert html =~
               "No Mac is enrolled. iMessage goes out through a Mac that runs the program and is signed in to Messages."

      assert html =~ "SMS"
      assert html =~ "Twilio"
    end

    test "offers the Macs and says what the Mac must be told", %{conn: conn, mac: mac} do
      {:ok, view, html} = live(signed_in(conn), "/alerts")
      assert html =~ "mac-mini" and html =~ "mac-air"
      refute html =~ ">vault<"
      assert html =~ "dokkit imessage on"
      assert html =~ "macOS asks once"
      refute html =~ "will not send until a Mac is chosen"

      Alerts.save(%{"imessage_machine" => "", "down" => "imessage"})
      {:ok, _, html} = live(signed_in(conn), "/alerts")
      assert html =~ "will not send until a Mac is chosen"

      html =
        view
        |> form("#alerts-form", alerts: %{imessage_machine: mac.id, imessage_to: "+15555550100"})
        |> render_submit()

      assert html =~ "Saved"
      assert Alerts.config()["imessage_machine"] == mac.id
    end

    test "the iMessage test shows the Mac's answer when it arrives", %{conn: conn, mac_key: key} do
      {:ok, view, _} = live(signed_in(conn), "/alerts")
      html = view |> form("#alerts-form") |> render_submit(%{"test" => "imessage"})
      assert html =~ "Waiting for the Mac"

      run =
        Enum.find_value(1..50, fn _ ->
          case work(key) do
            %{status: 200} = c -> json_response(c, 200)
            _ -> Process.sleep(100) && nil
          end
        end)

      result(key, run["run"], %{exit_code: 0})
      assert render_async(view, 2000) =~ "Sent. Check that it arrived."
    end
  end
end
