defmodule Dokkit.StartupTest do
  use Dokkit.DataCase, async: true
  import ExUnit.CaptureLog
  alias Dokkit.{Accounts, Repo, Watch}

  test "announce survives a database that is not there yet" do
    Repo.put_dynamic_repo(:no_such_repo)
    log = capture_log(fn -> assert Accounts.announce() end)
    assert log =~ "Could not check for an account"
    assert log =~ "setup code is:"
  end

  test "right after a start, a quiet machine is not flagged" do
    Req.Test.stub(Dokkit.Alerts, fn conn -> Plug.Conn.send_resp(conn, 202, "{}") end)

    Repo.insert!(%Dokkit.Machine{
      name: "startup-quiet01",
      kind: :enrolled,
      last_seen_at: DateTime.add(DateTime.utc_now(), -86_400)
    })

    now = DateTime.utc_now()
    assert Watch.sweep_quiet(DateTime.add(now, -60), now) == 0
    assert Watch.sweep_quiet(DateTime.add(now, -600), now) == 1
  end
end
