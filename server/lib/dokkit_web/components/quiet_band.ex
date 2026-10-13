defmodule DokkitWeb.QuietBand do
  @moduledoc "The band that says a machine is in planned downtime, and the control that starts one. Used on Everything and on a machine's page."
  use Phoenix.Component
  import DokkitWeb.Show, only: [ic: 1]

  @lengths [
    {"15m", "15 minutes"},
    {"30m", "30 minutes"},
    {"1h", "1 hour"},
    {"2h", "2 hours"},
    {"4h", "4 hours"}
  ]

  attr :machine, :string, required: true
  attr :planned, :any, default: nil
  attr :control, :boolean, default: false
  attr :disabled, :boolean, default: false

  def band(assigns) do
    assigns = assign(assigns, lengths: @lengths)

    ~H"""
    <div :if={@planned} class="foot" id={"quiet-#{@machine}"} role="status">
      <span style="flex: 1 1 260px">
        <.ic name="moon" /> <b>Planned downtime until {Calendar.strftime(@planned.until, "%H:%M")} UTC</b>{@planned.reason &&
          ": " <> @planned.reason}.
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
      <input type="hidden" name="quiet[machine]" value={@machine} /> <span>Planned downtime</span>
      <select class="inp" name="quiet[for]" aria-label="For how long">
        <option :for={{value, text} <- @lengths} value={value}>{text}</option>
      </select>
      
      <input
        class="inp"
        style="flex: 1 1 160px"
        name="quiet[reason]"
        maxlength="200"
        placeholder="Why (optional)"
        aria-label="Why"
      />
      <button class="btn sm" type="submit" disabled={@disabled}>
        {if @planned, do: "Replace", else: "Start"}
      </button>
    </form>
    """
  end

  @repeats [{"once", "Once"}, {"daily", "Every day"}, {"weekly", "Weekly"}]
  @days Enum.with_index(~w(Mon Tue Wed Thu Fri Sat Sun), 1)

  attr :machine, :string, required: true
  attr :schedules, :list, default: []
  attr :form, :map, default: %{}
  attr :error, :string, default: nil
  attr :zone, :string, required: true
  attr :disabled, :boolean, default: false

  def schedules(assigns) do
    assigns =
      assign(assigns,
        lengths: @lengths,
        repeats: @repeats,
        days: @days,
        repeat: assigns.form["repeat"] || "once",
        chosen: assigns.form["days"] || []
      )

    ~H"""
    <form
      class="foot form"
      id={"schedule-form-#{@machine}"}
      phx-change="schedule_form"
      phx-submit="schedule_add"
    >
      <span>Schedule downtime</span>
      <label>
        Repeat
        <select class="inp" name="schedule[repeat]">
          <option :for={{value, text} <- @repeats} value={value} selected={value == @repeat}>
            {text}
          </option>
        </select>
      </label>
      
      <label :if={@repeat == "once"}>
        When ({@zone})
        <input class="inp" type="datetime-local" name="schedule[at]" value={@form["at"]} />
      </label>
      
      <label :if={@repeat != "once"}>
        At ({@zone}) <input class="inp" type="time" name="schedule[time]" value={@form["time"]} />
      </label>
      
      <label>
        For
        <select class="inp" name="schedule[for]">
          <option :for={{value, text} <- @lengths} value={value} selected={value == @form["for"]}>
            {text}
          </option>
        </select>
      </label>
      
      <span :if={@repeat == "weekly"} role="group" aria-label="On these days" class="acts">
        <label :for={{name, n} <- @days} style="display: flex; align-items: center; gap: 4px">
          <input
            type="checkbox"
            name="schedule[days][]"
            value={n}
            checked={to_string(n) in @chosen}
          /> {name}
        </label>
      </span>
      
      <label style="flex: 1 1 160px">
        Why (optional)
        <input class="inp" name="schedule[reason]" maxlength="200" value={@form["reason"]} />
      </label>
       <button class="btn sm" type="submit" disabled={@disabled}>Schedule</button>
      <span :if={@error} class="bad" role="alert">{@error}</span>
    </form>

    <div :for={s <- @schedules} class="foot" id={"schedule-#{s.id}"}>
      <span style="flex: 1 1 260px">
        {s.text}.{s.next && " Next start #{s.next}."}
      </span>
      
      <span class="end">
        <button
          class="btn sm"
          type="button"
          phx-click="schedule_remove"
          phx-value-id={s.id}
          disabled={@disabled}
        >
          Remove
        </button>
      </span>
    </div>
    """
  end

  @doc "Schedules or removes a window for a person who may act."
  def add_schedule(socket, machine, p) do
    if socket.assigns.current_user.role != :viewer do
      config = Dokkit.Alerts.config()

      Dokkit.QuietSchedules.add(
        machine,
        %{
          "repeat" => p["repeat"],
          "at" => Dokkit.QuietSchedules.local_to_utc(p["at"], config),
          "time" => p["time"],
          "days" => p["days"],
          "for" => p["for"],
          "reason" => p["reason"]
        },
        socket.assigns.current_user.name
      )
      |> in_page_words(p)
    end
  end

  defp in_page_words({:error, "bad_schedule", _}, %{"repeat" => "once"}),
    do: {:error, "bad_schedule", "Choose a date and time that is still to come."}

  defp in_page_words({:error, "bad_schedule", _}, %{"repeat" => "weekly", "time" => time})
       when time not in [nil, ""],
       do: {:error, "bad_schedule", "Tick at least one day."}

  defp in_page_words({:error, "bad_schedule", _}, _),
    do: {:error, "bad_schedule", "Choose the time of day."}

  defp in_page_words(other, _), do: other

  def remove_schedule(socket, machine, id) do
    if socket.assigns.current_user.role != :viewer,
      do: Dokkit.QuietSchedules.remove(machine, id)
  end

  @doc "Starts or ends a window for a person who may act."
  def start(socket, %{"machine" => id} = p) do
    if socket.assigns.current_user.role != :viewer,
      do:
        Dokkit.Quiet.start(
          id,
          %{"for" => p["for"], "reason" => p["reason"]},
          socket.assigns.current_user.name
        )
  end

  def stop(socket, id) do
    if socket.assigns.current_user.role != :viewer,
      do: Dokkit.Quiet.stop(id, socket.assigns.current_user.name)
  end
end
