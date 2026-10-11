defmodule DokkitWeb.EnrolLive do
  use DokkitWeb, :live_view
  alias Dokkit.Keys

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Add a machine", token: nil)}

  def handle_info(:issues_changed, socket), do: {:noreply, socket}

  def handle_event("token", _, socket) do
    if socket.assigns.current_user.role == :owner do
      expires = DateTime.add(DateTime.utc_now(), 3600)

      {token, _} =
        Keys.mint(:enrol, %{
          expires_at: expires,
          label: "Made by #{socket.assigns.current_user.name}"
        })

      {:noreply, assign(socket, token: token)}
    else
      {:noreply, socket}
    end
  end

  # The fingerprint of the certificate this server serves, when it serves one itself.
  defp pin do
    with false <- Dokkit.Certificate.trusted_address?(),
         path when is_binary(path) <- Application.get_env(:dokkit, :cert),
         {:ok, pem} <- File.read(path),
         [{:Certificate, der, _} | _] <- :public_key.pem_decode(pem) do
      " sha256:" <> Base.encode16(:crypto.hash(:sha256, der), case: :lower)
    else
      _ -> ""
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app active={:all} shell={@shell} user={@current_user}>
      <div class="crumb">
        <.link navigate={~p"/all"}>Everything</.link><.ic name="caret-right" /><span>Add a machine</span>
      </div>
      <div class="head">
        <h1 tabindex="-1">Add a machine</h1>
      </div>
      <div class="body set">
        <div class="card">
          <h2>Enrol it</h2>
          <p class="lead">
            Put the dokkit program on the machine and run the two commands below there. The first trades a token for the machine's own key. The second stays running and tells Dokkit the machine is alive once a minute; three minutes of silence opens an issue.
          </p>
          <p class="lead">
            If the machine does not have the program yet, get it first. On Linux or macOS:
          </p>
          <pre class="logbox" id="get-unix">curl -fsSL https://dokkit.dev/get.sh | sh</pre>
          <p class="lead">On Windows, in PowerShell:</p>
          <pre class="logbox" id="get-windows">irm https://dokkit.dev/get.ps1 | iex</pre>
          <p :if={!@token and @current_user.role != :owner} class="lead">
            Only the owner can make a token.
          </p>
          <pre :if={@token} class="logbox" id="enrol-commands">dokkit enrol {Dokkit.Certificate.url()} {@token}{pin()}
    dokkit watch</pre>
          <div class="foot">
            <span :if={@token}>The token works once and runs out in an hour. It is shown only now.</span>
            <span class="end">
              <button
                class="btn primary"
                type="button"
                phx-click="token"
                disabled={@current_user.role != :owner}
              >
                {if @token, do: "Make another token", else: "Make a token"}
              </button>
            </span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
