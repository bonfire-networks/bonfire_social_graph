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
    object :familiar_followers do
      field(:id, :id)
      field(:accounts, list_of(:user))
    end

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

    # accepted follows, batched (`:follow_counts` source); not the `FollowCount` row, which counts pending requests
    def followers_count(user, _args, info), do: load_follow_count(user, info, :object_count)
    def following_count(user, _args, info), do: load_follow_count(user, info, :subject_count)

    @doc "`me.familiar_followers(ids:)`: for each id, up to 10 people the current user follows who follow it (`Follows.familiar_followers/3`); none for an id that is not one."
    def familiar_followers(_me, %{ids: ids}, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info) do
        {:ok, Enum.map(ids, &%{id: &1, accounts: familiar_accounts(user, &1)})}
      end
    end

    defp familiar_accounts(user, id) do
      if Bonfire.Common.Types.is_uid?(id) do
        {accounts, _total} = Bonfire.Social.Graph.Follows.familiar_followers(user, id, 10)
        accounts
      else
        []
      end
    end

    @doc "Follow requests waiting for the current user (`me.follow_requests_count`)."
    def follow_requests_count(_me, _args, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info) do
        {:ok, Bonfire.Social.Graph.Follows.count_requests(user)}
      end
    end

    def followers(user, args, info), do: list_user_follows(user, args, info, :followers)
    def following(user, args, info), do: list_user_follows(user, args, info, :following)

    def follow_requests(_parent, args, info), do: list_follow_requests(args, info, :incoming)

    def follow_requests_outgoing(_parent, args, info),
      do: list_follow_requests(args, info, :outgoing)

    def follow(%{id: to_follow}, info) do
      user = GraphQL.current_user(info)

      if user do
        # a client pressing Follow means "be following this", so a repeat answers with the follow that exists rather than erroring
        with {:ok, f} <- Bonfire.Social.Graph.Follows.maybe_follow(user, to_follow),
             {:ok, activity} <- follow_activity(f) do
          {:ok, activity}
        end
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

    defp follow_activity(follow_or_request) do
      follow_or_request
      |> Bonfire.Common.Repo.maybe_preload(:activity)
      |> e(:activity, nil)
      |> case do
        %{id: _} = activity -> {:ok, activity}
        _ -> {:error, "Could not resolve follow activity"}
      end
    end

    defp load_follow_count(user, %{context: %{loader: loader}}, field) do
      case Bonfire.Common.Types.uid(user) do
        nil ->
          {:ok, 0}

        user_id ->
          loader
          |> Dataloader.load(:follow_counts, :counts, user_id)
          |> Absinthe.Resolution.Helpers.on_load(fn loader ->
            {:ok,
             loader |> Dataloader.get(:follow_counts, :counts, user_id) |> follow_count(field)}
          end)
      end
    end

    defp follow_count(%{} = counts, field), do: Map.get(counts, field) || 0
    defp follow_count(_other, _field), do: 0

    defp list_user_follows(user, args, info, direction) do
      current_user = GraphQL.current_user(info)

      {list_fn, field, opts} =
        case direction do
          :followers ->
            {&Bonfire.Social.Graph.Follows.list_followers/2, :subject, []}

          # accounts only, as the web UI's followed tab (`follows_live_handler.ex`): a followed hashtag is not an account, and the Mastodon mapper dropped it from a page already counted
          :following ->
            {&Bonfire.Social.Graph.Follows.list_followed/2, :object,
             [exclude_object_types: [Bonfire.Tag.Hashtag]]}
        end

      list_fn.(
        user,
        [paginate: follows_paginate_opts(args), current_user: current_user] ++ opts
      )
      |> Bonfire.API.GraphQL.Pagination.connection_paginate(args)
      |> remap_follow_edges(field)
    end

    defp list_follow_requests(args, info, direction) do
      case GraphQL.current_user(info) do
        nil ->
          {:error, "Not authenticated"}

        current_user ->
          opts = [
            current_user: current_user,
            type: Bonfire.Data.Social.Follow,
            paginate: follows_paginate_opts(args)
          ]

          requests =
            case direction do
              :incoming -> Bonfire.Social.Requests.list_my_requesters(opts)
              :outgoing -> Bonfire.Social.Requests.list_my_requested(opts)
            end
            |> preload_request_edges()

          field = if direction == :incoming, do: :subject, else: :object

          requests
          |> Bonfire.API.GraphQL.Pagination.connection_paginate(args)
          |> remap_follow_edges(field)
      end
    end

    defp preload_request_edges(%{edges: requests} = page),
      do: %{page | edges: Bonfire.Common.Repo.maybe_preload(requests, edge: [:subject, :object])}

    defp preload_request_edges(other), do: other

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
