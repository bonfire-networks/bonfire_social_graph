defmodule Bonfire.Social.Graph.API.GraphQLTest do
  use Bonfire.Social.Graph.DataCase, async: false

  alias Bonfire.API.GraphQL.Schema

  @moduletag :graphql

  setup do
    alice = fake_user!()
    bob = fake_user!()
    {:ok, alice: alice, bob: bob}
  end

  # Queries alice's relationship with bob.
  # user(filter: {id: alice}) uses the parent user as subject (not current_user),
  # which is why a third-party current_user still sees alice's follow state
  # but gets nil for ghosting/silencing.
  @query """
  query Rel($userId: ID!, $otherId: ID!) {
    user(filter: {id: $userId}) { relationship(with: $otherId) { following followed requested ghosting silencing } }
  }
  """

  test "following/followed reflect actual follow state", %{alice: alice, bob: bob} do
    Bonfire.Social.Graph.Follows.follow(alice, bob)

    {:ok, result} =
      Absinthe.run(@query, Schema,
        variables: %{"userId" => alice.id, "otherId" => bob.id},
        context: Schema.context(%{current_user: alice})
      )

    rel = get_in(result, [:data, "user", "relationship"])
    assert rel["following"] == true
    assert rel["followed"] == false
    refute result[:errors]
  end

  test "followed is true when the other follows subject", %{alice: alice, bob: bob} do
    Bonfire.Social.Graph.Follows.follow(bob, alice)

    {:ok, result} =
      Absinthe.run(@query, Schema,
        variables: %{"userId" => alice.id, "otherId" => bob.id},
        context: Schema.context(%{current_user: alice})
      )

    rel = get_in(result, [:data, "user", "relationship"])
    assert rel["following"] == false
    assert rel["followed"] == true
  end

  test "ghosting is visible to the blocking user themselves", %{alice: alice, bob: bob} do
    Bonfire.Boundaries.Blocks.block(bob, :ghost, current_user: alice)

    {:ok, result} =
      Absinthe.run(@query, Schema,
        variables: %{"userId" => alice.id, "otherId" => bob.id},
        context: Schema.context(%{current_user: alice})
      )

    assert get_in(result, [:data, "user", "relationship", "ghosting"]) == true
  end

  test "ghosting and silencing are nil when queried by a third party", %{alice: alice, bob: bob} do
    third = fake_user!()
    Bonfire.Boundaries.Blocks.block(bob, :ghost, current_user: alice)

    {:ok, result} =
      Absinthe.run(@query, Schema,
        variables: %{"userId" => alice.id, "otherId" => bob.id},
        context: Schema.context(%{current_user: third})
      )

    rel = get_in(result, [:data, "user", "relationship"])
    assert rel["ghosting"] == nil
    assert rel["silencing"] == nil
  end

  test "requesting only 'following' does not error", %{alice: alice, bob: bob} do
    {:ok, result} =
      Absinthe.run(
        ~S|query($userId: ID!, $otherId: ID!) { user(filter: {id: $userId}) { relationship(with: $otherId) { following } } }|,
        Schema,
        variables: %{"userId" => alice.id, "otherId" => bob.id},
        context: Schema.context(%{current_user: alice})
      )

    assert get_in(result, [:data, "user", "relationship", "following"]) == false
    refute result[:errors]
  end
end
