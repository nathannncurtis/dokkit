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

  test "right after a start, nothing is flagged for being quiet" do
    now = DateTime.utc_now()
    refute Watch.settled?(DateTime.add(now, -60), now)
    assert Watch.settled?(DateTime.add(now, -600), now)
  end
end
