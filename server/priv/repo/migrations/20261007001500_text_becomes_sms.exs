defmodule Dokkit.Repo.Migrations.TextBecomesSms do
  use Ecto.Migration

  @doc "The statements, so a test can run them against its own rows."
  def statements do
    [
      "UPDATE services SET route_down = 'sms' WHERE route_down = 'text'",
      "UPDATE services SET route_degraded = 'sms' WHERE route_degraded = 'text'",
      "UPDATE settings SET value = jsonb_set(value, '{down}', '\"sms\"') WHERE key = 'alerts' AND value->>'down' = 'text'",
      "UPDATE settings SET value = jsonb_set(value, '{degraded}', '\"sms\"') WHERE key = 'alerts' AND value->>'degraded' = 'text'",
      "UPDATE settings SET value = value - 'text_to' WHERE key = 'alerts'",
      """
      UPDATE settings SET value = jsonb_set(value, '{list}', (
        SELECT coalesce(jsonb_agg(
          CASE WHEN r.e->>'channel' = 'text' THEN jsonb_set(r.e, '{channel}', '"sms"') ELSE r.e END
          ORDER BY r.n), '[]'::jsonb)
        FROM jsonb_array_elements(value->'list') WITH ORDINALITY AS r(e, n)))
      WHERE key = 'rules' AND jsonb_typeof(value->'list') = 'array'
      """,
      "UPDATE alerts SET channel = 'sms' WHERE channel = 'text' AND status IN ('pending', 'held', 'failed')"
    ]
  end

  def up, do: Enum.each(statements(), &execute/1)
  def down, do: :ok
end
