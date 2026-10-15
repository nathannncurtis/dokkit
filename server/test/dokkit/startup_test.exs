defmodule Dokkit.StartupTest do
  use Dokkit.DataCase, async: true
  import ExUnit.CaptureLog
  alias Dokkit.{Accounts, Repo}

  test "announce survives a database that is not there yet" do
    Repo.put_dynamic_repo(:no_such_repo)
    log = capture_log(fn -> assert Accounts.announce() end)
    assert log =~ "Could not check for an account"
    assert log =~ "setup code is:"
  end
end
