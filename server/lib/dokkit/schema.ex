defmodule Dokkit.Schema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end

defmodule Dokkit.Machine do
  use Dokkit.Schema

  schema "machines" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:enrolled, :seen, :group], default: :enrolled
    field :os, :string
    field :arch, :string
    field :program_version, :string
    field :last_seen_at, :utc_datetime_usec
    has_many :services, Dokkit.Service
    timestamps()
  end
end

defmodule Dokkit.Service do
  use Dokkit.Schema

  @states [:ok, :degraded, :down, :unknown, :unwatched]
  def states, do: @states

  schema "services" do
    field :slug, :string
    field :name, :string
    field :kind, Ecto.Enum, values: [:service, :job, :dependency, :app], default: :service
    field :environment, :string, default: "production"
    field :version, :string
    field :listens, :string
    field :watched, :boolean, default: true
    field :state, Ecto.Enum, values: @states, default: :unknown
    field :note, :string
    belongs_to :machine, Dokkit.Machine
    has_many :checks, Dokkit.Check
    timestamps()
  end
end

defmodule Dokkit.Check do
  use Dokkit.Schema

  @types ~w(http tcp process windows-service beat job stats threshold expiry custom)a

  schema "checks" do
    field :name, :string
    field :type, Ecto.Enum, values: @types
    field :source, Ecto.Enum, values: [:file, :interface, :reported], default: :interface
    field :config, :map, default: %{}
    field :fail_after, :integer, default: 3
    field :state, Ecto.Enum, values: [:ok, :degraded, :down, :unknown], default: :unknown
    field :fails, :integer, default: 0
    field :passes, :integer, default: 0
    field :value, :float
    field :note, :string
    field :checked_at, :utc_datetime_usec
    belongs_to :service, Dokkit.Service
    timestamps()
  end
end

defmodule Dokkit.Issue do
  use Dokkit.Schema

  schema "issues" do
    field :number, :integer, read_after_writes: true
    field :kind, :string
    field :state, Ecto.Enum, values: [:degraded, :down]
    field :title, :string
    field :count, :integer, default: 1
    field :since, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :snoozed_until, :utc_datetime_usec
    field :acknowledged_at, :utc_datetime_usec
    belongs_to :machine, Dokkit.Machine
    belongs_to :service, Dokkit.Service
    belongs_to :check, Dokkit.Check
    timestamps()
  end

  def short_id(%__MODULE__{number: n}), do: "DOK-#{n}"
end

defmodule Dokkit.Key do
  use Dokkit.Schema

  schema "keys" do
    field :kind, Ecto.Enum, values: [:enrol, :machine, :app, :user]
    field :hash, :binary
    field :hint, :string
    field :label, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    belongs_to :machine, Dokkit.Machine
    belongs_to :service, Dokkit.Service
    timestamps()
  end
end

defmodule Dokkit.JobRun do
  use Dokkit.Schema

  schema "job_runs" do
    field :run, :string
    field :result, Ecto.Enum, values: [:running, :ok, :fail], default: :running
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :exit_code, :integer
    field :duration_ms, :integer
    field :done, :integer
    field :total, :integer
    field :tail, :string
    belongs_to :check, Dokkit.Check
    timestamps()
  end
end

defmodule Dokkit.Batch do
  use Dokkit.Schema

  schema "batches" do
    field :accepted, :integer
    field :refused, {:array, :map}, default: []
    belongs_to :key, Dokkit.Key
    timestamps(updated_at: false)
  end
end
