defmodule DokkitWeb.SessionHTML do
  use DokkitWeb, :html

  attr :title, :string, required: true
  attr :error, :string, default: nil
  attr :action, :string, required: true
  attr :button, :string, required: true
  attr :value, :string, default: nil
  slot :lead
  slot :inner_block, required: true

  defp door(assigns) do
    ~H"""
    <main class="door">
      <form class="card" method="post" action={@action}>
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <h1><Layouts.mark />{@title}</h1>

        <p :if={@lead != []} class="mute">{render_slot(@lead)}</p>

        <p :if={@error} class="bad" role="alert">
          <i class="ph ph-warning" aria-hidden="true"></i>{@error}
        </p>
        {render_slot(@inner_block)}
        <button class="btn primary" type="submit" name={@value && "do"} value={@value}>
          {@button}
        </button>
      </form>
    </main>
    """
  end

  def login(assigns) do
    ~H"""
    <.door title="Sign in to Dokkit" error={@error} action={~p"/login"} button="Sign in">
      <label>
        Name<input class="inp" name="name" value={@name} autocomplete="username" required autofocus />
      </label>

      <label>
        Password<input
          class="inp"
          type="password"
          name="password"
          autocomplete="current-password"
          required
        />
      </label>
    </.door>
    """
  end

  defp code_field(assigns) do
    ~H"""
    <label>
      Code from your authenticator app<input
        class="inp mono"
        name="code"
        inputmode="numeric"
        pattern="[0-9 ]*"
        autocomplete="one-time-code"
        required
        autofocus
      />
    </label>
    """
  end

  def code(assigns) do
    ~H"""
    <.door title="Enter your code" error={@error} action={~p"/login/code"} button="Sign in">
      <label>
        Code from your authenticator app<input
          class="inp mono"
          name="code"
          autocomplete="one-time-code"
          autocapitalize="characters"
          spellcheck="false"
          required
          autofocus
        /> <small class="mute">Or one of your recovery codes.</small>
      </label>
      <a href={~p"/login"}>Start again</a>
    </.door>
    """
  end

  def two_step(%{on: true} = assigns) do
    ~H"""
    <.door
      title="Two-step sign-in is on"
      error={@error}
      action={~p"/two-step"}
      button="Turn it off"
      value="off"
    >
      <:lead>
        Signing in now asks for your password and then a code from your authenticator app. Nothing more to do here.
      </:lead>

      <p :if={@used} class="notice" role="status">
        <i class="ph ph-key" aria-hidden="true"></i>You signed in with a recovery code.
      </p>

      <p id="recovery-left">{recovery_left(@left)}</p>
      <.code_field />
      <small class="mute">
        Enter a current code to turn two-step sign-in off, or to make a new set of recovery codes. A new set ends the old one.
      </small>
      <button class="btn" type="submit" name="do" value="codes">Make new recovery codes</button>
      <a href={~p"/settings"}>Back to settings</a>
    </.door>
    """
  end

  def two_step(assigns) do
    ~H"""
    <.door title="Turn on two-step sign-in" error={@error} action={~p"/two-step"} button="Turn on">
      <:lead>Scan this with your authenticator app, then enter the code it shows.</:lead>

      <div class="qr">{Phoenix.HTML.raw(@qr)}</div>
      <small class="mute">Or type this key into the app: <code class="mono">{@secret}</code></small>
      <input type="hidden" name="do" value="on" /> <.code_field />
      <a href={~p"/settings"}>Back to settings</a>
    </.door>
    """
  end

  defp recovery_left(0), do: "You have no recovery codes left. Make a new set."
  defp recovery_left(1), do: "You have 1 recovery code left."
  defp recovery_left(n), do: "You have #{n} recovery codes left."

  defp codes_href(codes) do
    "data:text/plain;charset=utf-8," <>
      URI.encode(Enum.join(codes, "\n") <> "\n", &URI.char_unreserved?/1)
  end

  def codes(assigns) do
    ~H"""
    <main class="door">
      <section class="card">
        <h1><Layouts.mark />Save your recovery codes</h1>

        <p class="mute">
          Two-step sign-in is on. If you lose your authenticator app, each of these codes signs you in once, in place of its code. They are shown only now and cannot be shown again. Keep them somewhere safe.
        </p>
        <pre class="codes mono" id="recovery-codes">{Enum.join(@codes, "\n")}</pre>
        <div class="row">
          <button class="btn" type="button" data-copy="#recovery-codes">Copy</button>
          <a
            class="btn"
            id="recovery-download"
            download="dokkit-recovery-codes.txt"
            href={codes_href(@codes)}
          >
            Download
          </a>
        </div>
        <a class="btn primary" href={~p"/two-step"}>I have saved them</a>
      </section>
    </main>
    """
  end

  def password(assigns) do
    ~H"""
    <.door title="Change your password" error={@error} action={~p"/password"} button="Change password">
      <:lead :if={@done}>Your password is changed. Other devices are signed out.</:lead>

      <label>
        Current password<input
          class="inp"
          type="password"
          name="old"
          autocomplete="current-password"
          required
          autofocus
        />
      </label>

      <label>
        New password<input
          class="inp"
          type="password"
          name="new"
          autocomplete="new-password"
          minlength={Dokkit.Accounts.min_password()}
          required
        /> <small class="mute">At least {Dokkit.Accounts.min_password()} characters.</small>
      </label>
      <a href={~p"/settings"}>Back to settings</a>
    </.door>
    """
  end

  def setup(assigns) do
    ~H"""
    <.door title="Set up Dokkit" error={@error} action={~p"/setup"} button="Create the owner account">
      <:lead>
        This server has no account yet. It printed a setup code in its log when it started. Enter it here, so that nobody else on the network can claim the server first.
      </:lead>

      <label>
        Setup code<input
          class="inp mono"
          name="code"
          autocomplete="off"
          placeholder="XXXX-XXXX"
          required
          autofocus
        />
      </label>

      <label>
        Name<input class="inp" name="name" value={@name} autocomplete="username" required />
      </label>

      <label>
        Password<input
          class="inp"
          type="password"
          name="password"
          autocomplete="new-password"
          minlength={Dokkit.Accounts.min_password()}
          required
        /> <small class="mute">At least {Dokkit.Accounts.min_password()} characters.</small>
      </label>
    </.door>
    """
  end
end
