defmodule Bonfire.Social.Graph.Migrations do
  @moduledoc false
  use Ecto.Migration
  # import Needle.Migration

  def ms(:up) do
    quote do
      # require Bonfire.Data.Social.Block.Migration
      require Bonfire.Data.Social.Follow.Migration
      require Bonfire.Data.Social.Request.Migration

      # Bonfire.Data.Social.Block.Migration.migrate_block()
      Bonfire.Data.Social.Follow.Migration.migrate_follow()
      Bonfire.Data.Social.Request.Migration.migrate_request()
    end
  end

  def ms(:down) do
    quote do
      # require Bonfire.Data.Social.Block.Migration
      require Bonfire.Data.Social.Follow.Migration
      require Bonfire.Data.Social.Request.Migration

      Bonfire.Data.Social.Request.Migration.migrate_request()
      Bonfire.Data.Social.Follow.Migration.migrate_follow()
    end
  end

  defmacro migrate_social_graph() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(ms(:up)),
        else: unquote(ms(:down))
    end
  end

  defmacro migrate_social_graph(dir), do: ms(dir)
end
