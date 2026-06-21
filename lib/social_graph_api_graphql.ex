if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Social.Graph.API.GraphQL do
    use Absinthe.Schema.Notation
    use Bonfire.Common.Utils

    alias Bonfire.API.GraphQL

    # Relationship between two users.
    # Parent value: {subject, other} — set by the User.relationship field resolver.
    # Per-field resolvers: Absinthe only calls a resolver when that field is requested.
    # Privacy: ghosting/silencing are nil unless subject IS the requesting user.
    object :relationship do
      field(:following, :boolean) do
        resolve(fn {subject, other}, _, _ ->
          {:ok, Bonfire.Social.Graph.Follows.following?(subject, other)}
        end)
      end

      field(:followed, :boolean) do
        resolve(fn {subject, other}, _, _ ->
          {:ok, Bonfire.Social.Graph.Follows.following?(other, subject)}
        end)
      end

      field(:requested, :boolean) do
        resolve(fn {subject, other}, _, _ ->
          {:ok, Bonfire.Social.Graph.Follows.requested?(subject, other)}
        end)
      end

      field(:ghosting, :boolean) do
        resolve(fn {subject, other}, _, info ->
          if subject.id == e(GraphQL.current_user(info), :id, nil) do
            {:ok, Bonfire.Boundaries.Blocks.is_blocked?(other, :ghost, current_user: subject)}
          else
            {:ok, nil}
          end
        end)
      end

      field(:silencing, :boolean) do
        resolve(fn {subject, other}, _, info ->
          if subject.id == e(GraphQL.current_user(info), :id, nil) do
            {:ok, Bonfire.Boundaries.Blocks.is_blocked?(other, :silence, current_user: subject)}
          else
            {:ok, nil}
          end
        end)
      end
    end

    # relationship(with: other_id) on a User returns {subject_user, other_user}.
    # subject is the parent user being queried (NOT current_user), so that
    # a third party viewing alice's profile sees alice's follow state but
    # gets nil for ghosting/silencing (privacy rule).
    def relationship(subject, %{with: other_id}, _info) do
      with {:ok, other} <- Bonfire.Common.Needles.get(other_id, skip_boundary_check: true) do
        {:ok, {subject, other}}
      end
    end

    # Count the same edge set as the list resolvers; denormalized counts can lag imports.
    def followers_count(user, _args, _info), do: {:ok, count_follows(user, :objects)}
    def following_count(user, _args, _info), do: {:ok, count_follows(user, :subjects)}

    def followers(user, args, info), do: list_user_follows(user, args, info, :followers)
    def following(user, args, info), do: list_user_follows(user, args, info, :following)

    def follow_requests(_parent, args, info), do: list_follow_requests(args, info, :incoming)

    def follow_requests_outgoing(_parent, args, info),
      do: list_follow_requests(args, info, :outgoing)

    def follow(%{id: to_follow}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, f} <- Bonfire.Social.Graph.Follows.follow(user, to_follow),
             do: {:ok, e(f, :activity, nil)}
      else
        {:error, "Not authenticated"}
      end
    end

    def unfollow(%{id: to_unfollow}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, _} <- Bonfire.Social.Graph.Follows.unfollow(user, to_unfollow),
             do: {:ok, true}
      else
        {:error, "Not authenticated"}
      end
    end

    def accept_follow_request(%{id: requester_id}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, _} <-
               Bonfire.Social.Graph.Follows.accept_from(requester_id, current_user: user),
             do: {:ok, true}
      else
        {:error, "Not authenticated"}
      end
    end

    def reject_follow_request(%{id: requester_id}, info) do
      user = GraphQL.current_user(info)

      if user do
        with {:ok, _} <- Bonfire.Social.Graph.Follows.reject(requester_id, user, []),
             do: {:ok, true}
      else
        {:error, "Not authenticated"}
      end
    end

    defp count_follows(user, key) do
      case Bonfire.Common.Types.uid(user) do
        nil ->
          0

        user_id ->
          Bonfire.Social.Edges.count(Bonfire.Social.Graph.Follows, [{key, user_id}],
            skip_boundary_check: true
          ) || 0
      end
    end

    defp list_user_follows(user, args, info, direction) do
      current_user = GraphQL.current_user(info)

      {list_fn, field} =
        case direction do
          :followers -> {&Bonfire.Social.Graph.Follows.list_followers/2, :subject}
          :following -> {&Bonfire.Social.Graph.Follows.list_followed/2, :object}
        end

      list_fn.(user, paginate: follows_paginate_opts(args), current_user: current_user)
      |> Bonfire.API.GraphQL.Pagination.connection_paginate(args)
      |> remap_follow_edges(field)
    end

    defp list_follow_requests(args, info, direction) do
      case GraphQL.current_user(info) do
        nil ->
          {:error, "Not authenticated"}

        current_user ->
          requests =
            case direction do
              :incoming ->
                Bonfire.Social.Requests.list_my_requesters(
                  current_user: current_user,
                  type: Bonfire.Data.Social.Follow
                )

              :outgoing ->
                Bonfire.Social.Requests.list_my_requested(
                  current_user: current_user,
                  type: Bonfire.Data.Social.Follow
                )
            end
            |> Bonfire.Common.Repo.maybe_preload(edge: [:subject, :object])

          field = if direction == :incoming, do: :subject, else: :object

          requests
          |> Bonfire.API.GraphQL.Pagination.connection_paginate(args)
          |> remap_follow_edges(field)
      end
    end

    defp remap_follow_edges({:ok, %{edges: edges} = conn}, field) do
      remapped =
        edges
        |> Enum.map(&remap_follow_node(&1, field))
        |> Enum.reject(&is_nil(e(&1, :node, nil)))

      {:ok, %{conn | edges: remapped}}
    end

    defp remap_follow_edges(other, _field), do: other

    defp remap_follow_node(%{node: node_edge} = edge_map, field),
      do: %{edge_map | node: e(node_edge, field, nil) || e(node_edge, :edge, field, nil)}

    defp remap_follow_node(other, _field), do: other

    defp follows_paginate_opts(args) do
      []
      |> follows_put(:limit, args[:first] || args[:last])
      |> follows_put(:after, args[:after])
      |> follows_put(:before, args[:before])
    end

    defp follows_put(opts, _key, nil), do: opts
    defp follows_put(opts, key, val), do: Keyword.put(opts, key, val)
  end
end
