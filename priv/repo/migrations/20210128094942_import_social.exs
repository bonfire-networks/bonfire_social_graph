defmodule Bonfire.Social.Graph.Repo.Migrations.ImportSocial  do
  @moduledoc false
  use Ecto.Migration

  import Bonfire.Social.Graph.Migrations

  def change, do: migrate_social()
end
