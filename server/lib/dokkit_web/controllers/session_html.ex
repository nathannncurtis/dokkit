defmodule DokkitWeb.SessionHTML do
  use DokkitWeb, :html

  attr :title, :string, required: true
  attr :error, :string, default: nil
  attr :action, :string, required: true
  attr :button, :string, required: true
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
        {render_slot(@inner_block)} <button class="btn primary" type="submit">{@button}</button>
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
      <.code_field /> <a href={~p"/login"}>Start again</a>
    </.door>
    """
  end

  def two_step(%{on: true} = assigns) do
    ~H"""
    <.door title="Two-step sign-in is on" error={@error} action={~p"/two-step"} button="Turn it off">
      <:lead>
        Signing in now asks for your password and then a code from your authenticator app. Nothing more to do here. To turn it off, enter a code.
      </:lead>
      <.code_field /> <a href={~p"/settings"}>Back to settings</a>
    </.door>
    """
  end

  def two_step(assigns) do
    ~H"""
    <.door title="Turn on two-step sign-in" error={@error} action={~p"/two-step"} button="Turn on">
      <:lead>Scan this with your authenticator app, then enter the code it shows.</:lead>
      <div class="qr">{Phoenix.HTML.raw(@qr)}</div>
      <small class="mute">Or type this key into the app: <code class="mono">{@secret}</code></small>
      <.code_field /> <a href={~p"/settings"}>Back to settings</a>
    </.door>
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
