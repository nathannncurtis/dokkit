defmodule DokkitWeb.ReleaseDownloadTest do
  use ExUnit.Case, async: false
  alias Dokkit.TestCerts

  @size 48 * 1024 * 1024

  defmodule File48 do
    def init(path), do: path

    def call(conn, path),
      do:
        Plug.Conn.send_file(
          Plug.Conn.put_resp_content_type(conn, "application/octet-stream"),
          200,
          path
        )
  end

  @tag skip: if(System.find_executable("go"), do: false, else: "go is not installed")
  @tag timeout: 180_000
  test "the program's own client downloads a large release file over HTTP/2" do
    dir = Path.join(System.tmp_dir!(), "dokkit-h2-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(dir) end)
    cert = TestCerts.self_signed_ec(["localhost"], dir)
    file = Path.join(dir, "big.bin")
    File.write!(file, :binary.copy(<<0>>, @size))

    server =
      start_supervised!(
        {Bandit,
         plug: {File48, file},
         scheme: :https,
         ip: :loopback,
         port: 0,
         certfile: cert.path,
         keyfile: cert.key_path,
         http_2_options: Application.fetch_env!(:dokkit, :http_2_options)}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    pin = "sha256:" <> Base.encode16(:crypto.hash(:sha256, cert.der), case: :lower)

    {out, status} =
      System.cmd("go", ["test", "-count=1", "-run", "TestLargeFileOverHTTP2", "."],
        cd: Path.expand("../../../program", __DIR__),
        stderr_to_stdout: true,
        env: [
          {"DOKKIT_H2_URL", "https://localhost:#{port}/"},
          {"DOKKIT_H2_PIN", pin},
          {"DOKKIT_H2_SIZE", Integer.to_string(@size)}
        ]
      )

    assert status == 0, out
  end
end
