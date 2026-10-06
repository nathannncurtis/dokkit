defmodule Dokkit.Repo.Migrations.BoundLogPartitionsInUtc do
  use Ecto.Migration

  # Partitions made while the session zone was not UTC are re-attached with UTC bounds.
  def up do
    execute "SET LOCAL TIME ZONE 'UTC'"

    execute """
    DO $$
    DECLARE r record;
    BEGIN
      CREATE TEMP TABLE moved (name text, a timestamptz, b timestamptz) ON COMMIT DROP;
      FOR r IN
        SELECT c.relname AS name,
               make_date(substr(c.relname, 7, 4)::int, substr(c.relname, 12, 2)::int, 1) AS d
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
        WHERE p.relname = 'logs' AND c.relname ~ '^logs_y[0-9]{4}m[0-9]{2}$'
          AND pg_get_expr(c.relpartbound, c.oid) NOT LIKE '%00:00:00+00''%'
      LOOP
        EXECUTE format('ALTER TABLE logs DETACH PARTITION %I', r.name);
        INSERT INTO moved VALUES (r.name, (r.d::text || ' 00:00:00+00')::timestamptz,
                                  ((r.d + interval '1 month')::date::text || ' 00:00:00+00')::timestamptz);
      END LOOP;
      FOR r IN SELECT * FROM moved LOOP
        EXECUTE format('ALTER TABLE logs ATTACH PARTITION %I FOR VALUES FROM (%L) TO (%L)',
                       r.name, r.a, r.b);
      END LOOP;
    END $$
    """
  end

  def down, do: :ok
end
