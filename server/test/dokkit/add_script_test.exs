defmodule Dokkit.AddScriptTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{AddScript, Keys}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "dokkit-add-#{Base.encode16(:crypto.strong_rand_bytes(6))}")

    old = Application.get_env(:dokkit, :releases)
    Application.put_env(:dokkit, :releases, dir)
    on_exit(fn -> Application.put_env(:dokkit, :releases, old) end)

    for v <- ["v0.1.9", "v0.1.10"],
        f <- ["SHA256SUMS", "SHA256SUMS.sig", "dokkit-windows-amd64.exe"] do
      File.mkdir_p!(Path.join(dir, v))
      File.write!(Path.join([dir, v, f]), "#{v} #{f}")
    end

    File.mkdir_p!(Path.join(dir, "v0.1.11"))
    File.write!(Path.join([dir, "v0.1.11", "SHA256SUMS"]), "incomplete")
    :ok
  end

  defp fetch(token, file),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/v1/releases/v0.1.10/#{file}")

  test "the script carries the server, a working token, the newest complete release and the release key" do
    {token, key} = Keys.mint_enrol("front desk", 24 * 3600)
    {:ok, file, text} = AddScript.windows("Front Desk", token, key.expires_at)

    assert file == "dokkit-add-front-desk.ps1"
    assert text =~ "$token = '#{token}'"
    assert text =~ "$version = 'v0.1.10'"
    assert text =~ "$server = '#{Dokkit.Certificate.url()}'"
    refute text =~ "@@"
    assert text =~ "\r\n"
    refute text =~ ~r/[^\r]\n/
  end

  test "its signature check and release key are the ones in program/get.ps1" do
    get_ps1 = File.read!(Path.expand("../../../program/get.ps1", __DIR__))
    [_, fun] = Regex.run(~r/^(function Test-Ed25519.*?^})/ms, get_ps1)
    norm = &String.replace(&1, "\r\n", "\n")

    assert norm.(fun) ==
             norm.(
               String.trim_trailing(
                 File.read!(Application.app_dir(:dokkit, "priv/add/ed25519.ps1"))
               )
             )

    assert get_ps1 =~ "$releaseKey = '#{AddScript.release_key()}'"
  end

  test "a name with a quote cannot break out of the script's text" do
    {token, key} = Keys.mint_enrol("x", 3600)
    {:ok, _, text} = AddScript.windows("Bob's PC", token, key.expires_at)
    assert text =~ "as Bob''s PC"
  end

  test "an unused enrolment token may fetch release files; a used or revoked one may not" do
    {token, _} = Keys.mint_enrol("pc-1", 3600)
    assert response(fetch(token, "SHA256SUMS"), 200) == "v0.1.10 SHA256SUMS"
    assert response(fetch(token, "dokkit-windows-amd64.exe"), 200)

    {:ok, _} = Dokkit.Intake.enrol(token, %{"hostname" => "pc-1", "os" => "windows"})
    assert json_response(fetch(token, "SHA256SUMS"), 401)

    {other, key} = Keys.mint_enrol("pc-2", 3600)
    Keys.revoke(key.id)
    assert json_response(fetch(other, "SHA256SUMS"), 401)
    {user, _} = Keys.mint(:user, %{scopes: ["admin"]})
    assert json_response(fetch(user, "SHA256SUMS"), 401)
  end

  test "the page gives Windows one line to paste, and the script as a file to click", %{
    conn: conn
  } do
    {:ok, view, html} = live(signed_in(conn), "/machines/new")
    assert html =~ "Make the command"
    refute html =~ "get.ps1"

    html = view |> form("#token-form", os: "windows", name: "reception") |> render_submit()
    [_, token] = Regex.run(~r{irm \S+/add/(dke_\w+) \| iex}, html)
    assert html =~ ~s(download="dokkit-add-reception.ps1")
    [_, b64] = Regex.run(~r{href="data:text/plain;base64,([^"]+)"}, html)
    assert Base.decode64!(b64) =~ "$token = '#{token}'"
    assert html =~ "Waiting for the machine"
    assert html =~ ~r/(23 h 59|24 h 0)/

    {:ok, _} = Dokkit.Intake.enrol(token, %{"hostname" => "reception", "os" => "windows"})
    send(view.pid, :tick)
    assert render(view) =~ ~r/reception<\/a> is in/
  end

  test "the line's address hands out the script while its token is unused, and nothing after" do
    {token, _} = Keys.mint_enrol("lab-3", 3600)
    conn = get(build_conn(), "/add/#{token}")
    assert response(conn, 200) =~ "$token = '#{token}'"
    assert response_content_type(conn, :text)
    assert response(conn, 200) =~ "dokkit-add-lab-3.ps1"

    {:ok, _} = Dokkit.Intake.enrol(token, %{"hostname" => "lab-3", "os" => "windows"})
    assert response(get(build_conn(), "/add/#{token}"), 404) =~ "Make a new one"
    {user, _} = Keys.mint(:user, %{scopes: ["admin"]})
    assert response(get(build_conn(), "/add/#{user}"), 404)
    assert response(get(build_conn(), "/add/nonsense"), 404)
  end

  test "the API makes the same script, for admin tokens only" do
    {admin, _} = Keys.mint(:user, %{scopes: ["admin"]})
    {act, _} = Keys.mint(:user, %{scopes: ["read", "act"]})

    call = fn token ->
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/v1/add-script", %{name: "lab"})
    end

    assert %{"file" => "dokkit-add-lab.ps1", "script" => script} =
             json_response(call.(admin), 200)

    assert script =~ "dke_"
    assert json_response(call.(act), 403)
  end
end
