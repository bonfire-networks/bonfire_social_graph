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
  end
end
