defmodule Dokkit.RuntimeSettingsTest do
  # Reads real environment variables, so it cannot run beside other tests.
  use ExUnit.Case, async: false

  @names ~w(ProgramData DATABASE_URL SECRET_KEY_BASE PHX_HOST PORT DOKKIT_LOG_DIR)

  setup do
    saved = for n <- @names, do: {n, System.get_env(n)}

    on_exit(fn ->
      for {n, v} <- saved, do: if(v, do: System.put_env(n, v), else: System.delete_env(n))
    end)

    for n <- @names, do: System.delete_env(n)
    dir = Path.join(System.tmp_dir!(), "dokkit-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "Dokkit"))
    System.put_env("ProgramData", dir)
    {:ok, env_file: Path.join([dir, "Dokkit", "settings.env"])}
  end

  defp read, do: Config.Reader.read!("config/runtime.exs", env: :prod)

  test "a byte order mark and trailing spaces do not break the settings", %{env_file: file} do
    File.write!(
      file,
      "\uFEFFDATABASE_URL=ecto://u:p@localhost/d \r\nSECRET_KEY_BASE=abc \r\nPHX_HOST=dokkit.test \r\nPORT=4001 \r\nDOKKIT_LOG_DIR=C:/logs\r\n"
    )

    config = read()
    assert config[:dokkit][Dokkit.Repo][:url] == "ecto://u:p@localhost/d"
    assert config[:dokkit][DokkitWeb.Endpoint][:http][:port] == 4001
    assert config[:logger][:default_handler][:config][:file] == ~c"C:/logs/dokkit.log"
  end

  test "a missing PHX_HOST is an error, not example.com", %{env_file: file} do
    File.write!(file, "DATABASE_URL=ecto://u:p@localhost/d\nSECRET_KEY_BASE=abc\n")
    assert_raise RuntimeError, ~r/PHX_HOST is missing/, &read/0
  end
end
