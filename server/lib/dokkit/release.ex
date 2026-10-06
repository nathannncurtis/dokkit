defmodule Dokkit.Release do
  @moduledoc "What a packaged server runs before it starts: bin/dokkit eval Dokkit.Release.migrate"

  def migrate do
    Application.load(:dokkit)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Dokkit.Repo, &Ecto.Migrator.run(&1, :up, all: true))
  end
end
