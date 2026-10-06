defmodule Dokkit.Repo.Migrations.CreateLogs do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    execute """
    CREATE TABLE logs (
      id bigserial NOT NULL,
      at timestamptz NOT NULL,
      received_at timestamptz NOT NULL,
      machine_id uuid NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
      service_id uuid REFERENCES services(id) ON DELETE CASCADE,
      level text NOT NULL,
      msg text NOT NULL,
      fields jsonb NOT NULL DEFAULT '{}',
      cut boolean NOT NULL DEFAULT false,
      PRIMARY KEY (id, at)
    ) PARTITION BY RANGE (at)
    """

    execute "CREATE INDEX logs_at_index ON logs (at DESC, id DESC)"
    execute "CREATE INDEX logs_service_at_index ON logs (service_id, at DESC)"
    execute "CREATE INDEX logs_msg_index ON logs USING gin (msg gin_trgm_ops)"
  end

  def down do
    execute "DROP TABLE logs"
  end
end
