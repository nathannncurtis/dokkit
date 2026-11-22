defmodule Dokkit.Power do
  @moduledoc """
  A UPS's power and battery states, and a restart without a shutdown, judged against the
  machine's settings. Each power cut is one issue, closed with how long it lasted and the lowest charge.
  """
  import Ecto.Query
  alias Dokkit.{Check, Issue, Issues, Machine, Metric, Repo, Service, Values}

  @checks ~w(hw.ups.power hw.ups.battery hw.restart)

  def check?(name), do: name in @checks

  def record(%Check{} = check, %Service{machine_id: id}, state, line, at) do
    machine = Repo.get!(Machine, id)
    values = Values.all({:machine, id})
    once = %{check | fail_after: 1, config: Map.put(check.config, "own_fail_after", true)}
    judge(check.name, once, machine, values, state, number(line["value"]), line["note"], at)
    :ok
  end

  defp judge("hw.ups.power", check, machine, values, state, charge, _, at) do
    cfg = check.config

    cond do
      not values["ups_power_on"] ->
        check |> set(Map.drop(cfg, ~w(out_since back_since lowest))) |> Issues.record(:ok, at: at)

      state != :ok ->
        cfg =
          cfg
          |> Map.put_new("out_since", iso(at))
          |> Map.put("lowest", lowest(cfg["lowest"], charge))
          |> Map.drop(~w(back_since mains_since))

        check
        |> set(cfg)
        |> Issues.record(:down,
          at: at,
          value: charge,
          title: "Power is out at #{machine.name}",
          note: "On battery for #{span(cfg["out_since"], at)}#{left(charge)}."
        )

      cfg["out_since"] ->
        back = cfg["back_since"] || iso(at)

        if DateTime.diff(at, time(back)) >= values["ups_power_minutes"] * 60 do
          issue =
            Repo.one(from i in Issue, where: i.check_id == ^check.id and is_nil(i.closed_at))

          check
          |> set(
            cfg
            |> Map.drop(~w(out_since back_since lowest))
            |> Map.put("mains_since", back)
          )
          |> Issues.record(:ok, at: at, value: charge)

          if issue do
            lowest =
              if cfg["lowest"], do: " The lowest charge was #{num(cfg["lowest"])}%.", else: ""

            Issues.note(
              issue.id,
              "Power was out for #{span(cfg["out_since"], time(back))}.#{lowest}",
              "Dokkit"
            )
          end
        else
          check
          |> set(Map.put(cfg, "back_since", back))
          |> Issues.record(:down,
            at: at,
            value: charge,
            title: "Power is out at #{machine.name}",
            note:
              "Back on mains for #{span(back, at)}; closes after #{values["ups_power_minutes"]} minutes."
          )
        end

      true ->
        check |> set(Map.put_new(cfg, "mains_since", iso(at))) |> Issues.record(:ok, at: at)
    end
  end

  defp judge("hw.ups.battery", check, machine, values, state, charge, note, at) do
    power = Repo.get_by(Check, service_id: check.service_id, name: "hw.ups.power")
    out? = power != nil and power.config["out_since"] != nil and power.config["back_since"] == nil
    mains = power && power.config["mains_since"]
    charge = charge || latest(machine.id, "ups.charge_percent")
    runtime = latest(machine.id, "ups.runtime_minutes")

    reasons =
      [
        state != :ok && note,
        (out? and is_number(runtime) and runtime < values["ups_runtime_limit"]) &&
          "About #{num(runtime)} minutes of battery left",
        (out? and is_number(charge) and charge < values["ups_charge_limit"]) &&
          "The battery is at #{num(charge)}%",
        (not out? and is_binary(mains) and is_number(charge) and
           charge < values["ups_charge_mains"] and
           DateTime.diff(at, time(mains)) >= values["ups_charge_hours"] * 3600) &&
          "The battery is charged to only #{num(charge)}% after #{values["ups_charge_hours"]} hours on mains"
      ]
      |> Enum.filter(&is_binary/1)

    if values["ups_battery_on"] and reasons != [] do
      Issues.record(check, :degraded,
        at: at,
        value: charge,
        title:
          if(out?,
            do: "The UPS battery is running low at #{machine.name}",
            else: "The UPS battery needs a look at #{machine.name}"
          ),
        note: Enum.join(reasons, ". ") <> "."
      )
    else
      Issues.record(check, :ok, at: at, value: charge)
    end
  end

  defp judge("hw.restart", check, machine, values, state, boot, _, at) do
    started = is_number(boot) && DateTime.from_unix!(trunc(boot))

    if (state != :ok and values["restart_on"] and started) &&
         DateTime.diff(at, started) < values["restart_hours"] * 3600 do
      Issues.record(check, :degraded,
        at: at,
        value: boot,
        title: "#{machine.name} restarted without shutting down",
        note:
          "It started again at #{Calendar.strftime(started, "%Y-%m-%d %H:%M")} UTC after stopping without a shutdown, as a power cut leaves it."
      )
    else
      Issues.record(check, :ok, at: at)
    end
  end

  defp latest(machine_id, name) do
    Repo.one(
      from m in Metric,
        where: m.machine_id == ^machine_id and is_nil(m.service_id) and m.name == ^name,
        order_by: [desc: m.at],
        limit: 1,
        select: m.value
    )
  end

  defp set(%Check{config: config} = check, config), do: check

  defp set(check, config) do
    saved =
      Repo.update!(Ecto.Changeset.change(check, config: Map.delete(config, "own_fail_after")))

    %{check | config: Map.put(saved.config, "own_fail_after", true)}
  end

  defp lowest(old, new) when is_number(old) and is_number(new), do: min(old, new)
  defp lowest(old, new), do: if(is_number(new), do: new, else: old)

  defp left(charge) when is_number(charge), do: ", #{num(charge)}% charge left"
  defp left(_), do: ""

  defp span(from, to) do
    minutes = div(max(DateTime.diff(to, time(from)), 0), 60)

    cond do
      minutes < 1 -> "under a minute"
      minutes == 1 -> "1 minute"
      minutes < 120 -> "#{minutes} minutes"
      true -> "#{div(minutes, 60)} hours #{rem(minutes, 60)} minutes"
    end
  end

  defp time(%DateTime{} = t), do: t
  defp time(iso), do: iso |> DateTime.from_iso8601() |> elem(1)
  defp iso(at), do: DateTime.to_iso8601(at)

  defp number(v) when is_number(v), do: v / 1
  defp number(_), do: nil

  defp num(value) do
    value = value / 1
    if value == Float.round(value), do: trunc(value), else: Float.round(value, 1)
  end
end
