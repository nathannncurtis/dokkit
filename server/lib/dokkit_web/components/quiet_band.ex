defmodule DokkitWeb.QuietBand do
  @moduledoc "The band that says a machine is in planned downtime, and the control that starts one. Used on Everything and on a machine's page."
  use Phoenix.Component
  import DokkitWeb.Show, only: [ic: 1]

  @lengths [{"15m", "15 minutes"}, {"30m", "30 minutes"}, {"1h", "1 hour"}, {"2h", "2 hours"}, {"4h", "4 hours"}]

  attr :machine, :string, required: true
  attr :planned, :any, default: nil
  attr :control, :boolean, default: false
  attr :disabled, :boolean, default: false

  def band(assigns) do
    assigns = assign(assigns, lengths: @lengths)

    ~H"""
    <div :if={@planned} class="foot" id={"quiet-#{@machine}"} role="status">
      <.ic name="moon" />
      <span>
        <b>Planned downtime until {Calendar.strftime(@planned.until, "%H:%M")} UTC</b>{@planned.reason && ": " <> @planned.reason}.
        Alerts for this machine are off until then.
      </span>
      <span class="end">
        <button
          class="btn sm"
          type="button"
          phx-click="quiet_end"
          phx-value-machine={@machine}
          disabled={@disabled}
        >
          End now
        </button>
      </span>
    </div>
    <form
      :if={@control}
      class="foot"
      id={"quiet-form-#{@machine}"}
      phx-submit="quiet_start"
    >
      <input type="hidden" name="quiet[machine]" value={@machine} />
      <span>Planned downtime</span>
      <select class="inp" name="quiet[for]" aria-label="For how long">
        <option :for={{value, text} <- @lengths} value={value}>{text}</option>
      </select>
      <input
        class="inp"
        name="quiet[reason]"
        maxlength="200"
        placeholder="Why, such as nightly update"
        aria-label="Why"
      />
      <button class="btn sm" type="submit" disabled={@disabled}>
        {if @planned, do: "Replace", else: "Start"}
      </button>
    </form>
    """
  end

  @doc "Starts or ends a window for a person who may act."
  def start(socket, %{"machine" => id} = p) do
    if socket.assigns.current_user.role != :viewer,
      do: Dokkit.Quiet.start(id, %{"for" => p["for"], "reason" => p["reason"]}, socket.assigns.current_user.name)
  end

  def stop(socket, id) do
    if socket.assigns.current_user.role != :viewer,
      do: Dokkit.Quiet.stop(id, socket.assigns.current_user.name)
  end
end
