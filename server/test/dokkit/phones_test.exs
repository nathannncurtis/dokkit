defmodule Dokkit.PhonesTest do
  use DokkitWeb.ConnCase, async: false
  alias Dokkit.{Alerts, Check, Estate, Keys, Phone, Phones, Repo, Setting}
  alias Dokkit.Phones.Snapshot

  @cases Path.expand("../../../spec/phone-cases/sealing.json", __DIR__)
  @address "https://relay.example.test"
  @upload_key "dkr_729nLrMYIgy8I0YoubM6pyvho0c71L4IJO9Y"
  @mailbox "92bea4d52a1d53f0c8111edf39e26a89"

  defp vectors, do: @cases |> File.read!() |> Jason.decode!()

  defp open(key, nonce, sealed, aad) do
    raw = Base.decode64!(sealed)
    size = byte_size(raw) - 16
    <<cipher::binary-size(^size), tag::binary-16>> = raw

    :crypto.crypto_one_time_aead(
      :aes_256_gcm,
      key,
      Base.decode64!(nonce),
      cipher,
      aad,
      tag,
      false
    )
  end

  describe "sealing" do
    test "the fixed envelope opens with each phone's key and gives the snapshot back" do
      v = vectors()
      env = v["envelope"]
      content_key = Base.decode64!(v["content_key"])

      for phone <- v["phones"] do
        slot = env["slots"][phone["slot"]]

        assert slot["token_sha256"] ==
                 :crypto.hash(:sha256, phone["token"]) |> Base.encode16(case: :lower)

        wrapped =
          open(
            Base.decode64!(phone["phone_key"]),
            slot["nonce"],
            slot["key"],
            Phones.aad(v["mailbox"], phone["slot"], v["counter"])
          )

        assert wrapped == content_key

        body =
          open(wrapped, env["nonce"], env["body"], Phones.aad(v["mailbox"], "body", v["counter"]))

        assert body |> :zlib.gunzip() == v["snapshot_json"]
        assert Phones.aad(v["mailbox"], "body", v["counter"]) == v["body_additional_data"]
      end
    end

    test "everything the vectors say must fail, fails" do
      v = vectors()
      env = v["envelope"]
      [first, second | _] = v["phones"]
      slot = env["slots"][first["slot"]]
      key = Base.decode64!(first["phone_key"])
      content_key = Base.decode64!(v["content_key"])

      assert open(
               content_key,
               env["nonce"],
               env["body"],
               Phones.aad(v["mailbox"], "body", v["counter"] + 1)
             ) == :error

      assert open(
               key,
               slot["nonce"],
               slot["key"],
               Phones.aad(v["mailbox"], second["slot"], v["counter"])
             ) == :error

      assert open(
               Base.decode64!(second["phone_key"]),
               slot["nonce"],
               slot["key"],
               Phones.aad(v["mailbox"], first["slot"], v["counter"])
             ) == :error

      flip = fn text ->
        <<b, rest::binary>> = Base.decode64!(text)
        Base.encode64(<<Bitwise.bxor(b, 1), rest::binary>>)
      end

      aad = Phones.aad(v["mailbox"], "body", v["counter"])
      assert open(content_key, env["nonce"], flip.(env["body"]), aad) == :error

      assert open(
               key,
               slot["nonce"],
               flip.(slot["key"]),
               Phones.aad(v["mailbox"], first["slot"], v["counter"])
             ) ==
               :error

      assert Keys.kind(first["token"]) == {:ok, :fetch}
      assert Keys.kind(v["upload_key"]) == {:ok, :upload}
      bad = String.slice(first["token"], 0, 4 + 30) <> "000000"
      assert Keys.kind(bad) == :error
    end

    test "an envelope this code seals opens for each phone and not for a removed one" do
      phones =
        for slot <- ~w(aa bb) do
          %{
            slot: slot,
            key: :crypto.strong_rand_bytes(32),
            token_hash: :crypto.hash(:sha256, slot)
          }
        end

      now = ~U[2026-10-14 03:20:00.123Z]
      env = Phones.seal("{\"schema\":1}", @mailbox, 77, now, phones)
      assert env.made_at == "2026-10-14T03:20:00Z"
      assert Map.keys(env.slots) |> Enum.sort() == ["aa", "bb"]

      for p <- phones do
        s = env.slots[p.slot]
        content = open(p.key, s.nonce, s.key, Phones.aad(@mailbox, p.slot, 77))
        assert byte_size(content) == 32

        assert open(content, env.nonce, env.body, Phones.aad(@mailbox, "body", 77))
               |> :zlib.gunzip() == "{\"schema\":1}"
      end
    end

    test "a fetch token made here has the key format" do
      assert {:ok, :fetch} = Keys.kind(Keys.generate(:fetch))
    end
  end

  describe "the snapshot" do
    setup do
      Alerts.save(%{
        "pagerduty_key" => "SECRET-PD",
        "smtp_password" => "SECRET-SMTP",
        "email_to" => "ops@example.test"
      })

      {:ok, job} =
        Estate.add_job(%{
          "name" => "Nightly backup",
          "machine" => "nas",
          "schedule" => "0 1 * * *"
        })

      service = Estate.service(job.service.id)
      Estate.set(service, :restart, true)
      Estate.set(service, :keep_messages, true)
      machine = Repo.get_by!(Dokkit.Machine, name: "nas")
      Estate.set_silent(Estate.machine(machine.id), %{"down" => "page"})

      post(
        build_conn() |> put_req_header("content-type", "text/plain"),
        "/api/v1/in/#{job.key}/job/nightly-backup/fail",
        "disk full"
      )

      report(job.key, [%{type: "log", level: "error", msg: "rsync: disk full"}])
      :ok
    end

    defp names(%{} = map), do: Enum.flat_map(map, fn {k, v} -> [k | names(v)] end)
    defp names(list) when is_list(list), do: Enum.flat_map(list, &names/1)
    defp names(_), do: []

    test "holds what the API answers and none of the keys, destinations or settings" do
      doc = Snapshot.build(5, DateTime.utc_now())
      assert doc["server"]["counter"] == 5
      assert doc["server"]["left_out"] == []
      assert [%{"title" => _} | _] = doc["inbox"]["needs_you"]
      assert [service] = Enum.filter(doc["services"], &(&1["slug"] == "nightly-backup"))
      assert length(service["chart"]["values"]) == 24
      assert [_ | _] = doc["jobs"]
      assert [line] = doc["logs"][service["id"]]
      assert Map.keys(line) |> Enum.sort() == ~w(level msg t)

      forbidden =
        ~w(routing restart keep_messages silent thresholds config key token password secret
                     smtp_password pagerduty_key ntfy_token pushover_token twilio_token email_to webhook_url)

      assert Enum.filter(names(doc), &(&1 in forbidden)) == []
      text = Jason.encode!(doc)
      refute text =~ "SECRET-PD"
      refute text =~ "SECRET-SMTP"
      refute text =~ "ops@example.test"
      refute text =~ "\"tail\""
    end

    test "leaves out logs, then charts, when it would be too big, and says so" do
      doc = Snapshot.build(5, DateTime.utc_now(), max: 1)
      assert doc["server"]["left_out"] == ["logs", "chart"]
      assert doc["logs"] == %{}
      assert Enum.all?(doc["services"], &(not Map.has_key?(&1, "chart")))
    end

    test "the history of an issue is cut to the last 20 events" do
      [issue | _] = Dokkit.Read.issues()
      for n <- 1..30, do: Dokkit.Issues.note(issue.id, "note #{n}", "t")
      doc = Snapshot.build(5, DateTime.utc_now())
      assert [%{"history" => history}] = doc["issues"] |> Enum.filter(&(&1["id"] == issue.id))
      assert length(history) == 20
    end
  end

  describe "uploading" do
    setup do
      test = self()

      Req.Test.stub(Alerts, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        env = Jason.decode!(body)

        send(
          test,
          {:put, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
           env}
        )

        {status, answer} = Agent.get(:phone_answer, & &1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(answer))
      end)

      {:ok, _} =
        Agent.start_link(fn -> {200, %{"ok" => true, "slots" => %{}}} end, name: :phone_answer)

      {:ok, _} =
        Phones.save_relay(%{
          "address" => @address <> "/",
          "mailbox" => @mailbox,
          "key" => @upload_key
        })

      :ok
    end

    defp answer(status, body), do: Agent.update(:phone_answer, fn _ -> {status, body} end)
    defp state, do: Repo.get(Setting, "phone_state").value

    test "nothing goes while no phone is paired, and the key is never shown" do
      assert Phones.upload() == :skipped
      refute_received {:put, _, _, _, _}
      assert Phones.relay_view().key == "set"
      assert Phones.relay_view().address == @address
    end

    test "a pairing code holds the relay, the mailbox, the slot, the token and the key" do
      {:ok, phone, "dokkit-phone:1:" <> code} = Phones.add("Work iPhone")
      pairing = code |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert pairing["relay"] == @address
      assert pairing["mailbox"] == @mailbox
      assert pairing["slot"] == phone.slot
      assert Base.decode64!(pairing["key"]) == phone.key
      assert :crypto.hash(:sha256, pairing["token"]) == phone.token_hash
      assert {:ok, :fetch} = Keys.kind(pairing["token"])
      refute Phones.list() |> inspect() =~ pairing["token"]
    end

    test "an upload is a PUT with the key, sealed for each phone, and keeps each slot's last fetch" do
      {:ok, one, _} = Phones.add("one")
      assert_received {:put, "PUT", path, ["Bearer " <> @upload_key], env}
      assert path == "/m/" <> @mailbox
      assert Map.keys(env["slots"]) == [one.slot]

      answer(200, %{"ok" => true, "slots" => %{one.slot => "2026-10-13T10:00:00Z"}})
      assert Phones.upload() == :ok
      assert Repo.get!(Phone, one.id).last_fetch_at == ~U[2026-10-13 10:00:00.000000Z]
      assert state()["failing_since"] == nil
    end

    test "removing a phone uploads at once and the next envelope has no slot for it" do
      {:ok, one, _} = Phones.add("one")
      {:ok, two, _} = Phones.add("two")
      flush()
      assert Phones.remove(one.id) == :ok
      assert_received {:put, _, _, _, env}
      assert Map.keys(env["slots"]) == [two.slot]
      assert Phones.remove(one.id) == :not_found
      assert Phones.remove(two.id) == :ok
      assert_received {:put, _, _, _, %{"slots" => empty}}
      assert empty == %{}
    end

    test "the counter only goes up, across a restart and after a 409" do
      {:ok, _, _} = Phones.add("one")
      assert_received {:put, _, _, _, first}
      assert first["counter"] >= DateTime.to_unix(DateTime.utc_now()) - 5

      high = first["counter"] + 100_000

      Repo.insert!(%Setting{key: "phone_state", value: Map.put(state(), "counter", high)},
        on_conflict: {:replace, [:value]},
        conflict_target: :key
      )

      assert Phones.upload() == :ok
      assert_received {:put, _, _, _, second}
      assert second["counter"] == high + 1

      answer(409, %{"error" => %{"code" => "stale_counter", "message" => "no"}})
      assert {:error, why} = Phones.upload()
      assert why =~ "higher counter"
      assert_received {:put, _, _, _, third}
      assert third["counter"] == second["counter"] + 1

      answer(200, %{"ok" => true, "slots" => %{}})
      assert Phones.upload() == :ok
      assert_received {:put, _, _, _, fourth}
      assert fourth["counter"] > third["counter"]
    end

    test "a timeout or an error answer is a failure, and five minutes of failure shows on Dokkit's row until a good upload" do
      {:ok, _, _} = Phones.add("one")
      flush()
      now = DateTime.utc_now()
      Req.Test.stub(Alerts, &Req.Test.transport_error(&1, :timeout))
      assert {:error, why} = Phones.upload()
      assert why =~ "did not answer"
      assert Phones.trouble(now) == nil
      assert Phones.relay_view().last_error == why

      later = DateTime.add(now, 301)
      assert Phones.trouble(later) == why
      Dokkit.Self.tick(later, %{})
      assert relay_check().state == :degraded
      assert relay_check().note == why

      Req.Test.stub(Alerts, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      assert {:error, "The relay answered 503."} = Phones.upload()

      Req.Test.stub(Alerts, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"ok":true,"slots":{}}))
      end)

      assert Phones.upload() == :ok
      assert Phones.trouble(later) == nil
      Dokkit.Self.tick(later, %{})
      assert relay_check().state == :ok
    end

    test "a different mailbox pairs each phone again, the same one keeps them" do
      {:ok, _, _} = Phones.add("one")

      assert {:ok, _} =
               Phones.save_relay(%{"address" => @address, "mailbox" => @mailbox, "key" => ""})

      assert length(Phones.list()) == 1
      assert Phones.relay()["key"] == @upload_key

      other = String.duplicate("a", 32)

      assert {:ok, _} =
               Phones.save_relay(%{
                 "address" => @address <> "/m/" <> other,
                 "mailbox" => "",
                 "key" => ""
               })

      assert Phones.relay()["mailbox"] == other
      assert Phones.list() == []
    end

    test "a relay address must be https, a mailbox 32 hex characters, a key a relay upload key" do
      assert {:error, _} =
               Phones.save_relay(%{
                 "address" => "http://relay.example.test",
                 "mailbox" => @mailbox,
                 "key" => ""
               })

      assert {:error, "The mailbox" <> _} =
               Phones.save_relay(%{"address" => @address, "mailbox" => "nope", "key" => ""})

      assert {:error, "The upload key" <> _} =
               Phones.save_relay(%{
                 "address" => @address,
                 "mailbox" => @mailbox,
                 "key" => "dkr_bad"
               })

      Repo.delete_all(Setting)
      assert {:error, "Set the relay" <> _} = Phones.add("x")
    end

    defp relay_check do
      service = Repo.get_by!(Dokkit.Service, slug: "dokkit")
      Repo.get_by!(Check, service_id: service.id, name: "relay")
    end

    defp flush do
      receive do
        {:put, _, _, _, _} -> flush()
      after
        0 -> :ok
      end
    end
  end
end
