defmodule Bonfire.Social.Graph.FollowCounts do
  @moduledoc "Batch loading of follow counts for multiple users."

  use Bonfire.Common.Repo
  import Ecto.Query
  alias Bonfire.Common.Types

  def batch_load(users) when is_list(users) do
    user_ids =
      users
      |> Enum.map(&Types.uid/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if user_ids == [] do
      %{}
    else
      from(fc in Bonfire.Data.Social.FollowCount,
        where: fc.id in ^user_ids,
        select: {fc.id, %{followers: fc.object_count, following: fc.subject_count}}
      )
      |> repo().all()
      |> Map.new()
    end
  end

  def batch_load(_), do: %{}
end
