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

  @follow_mutation """
  mutation Follow($id: String!, $username: String!) {
    follow(id: $id, username: $username) {
      id
    }
  }
  """

  @unfollow_mutation """
  mutation Unfollow($id: String!) {
    unfollow(id: $id)
  }
  """

  @accept_follow_request_mutation """
  mutation AcceptFollowRequest($id: ID!) {
    acceptFollowRequest(id: $id)
  }
  """

  @reject_follow_request_mutation """
  mutation RejectFollowRequest($id: ID!) {
    rejectFollowRequest(id: $id)
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

  test "another user's profile returns a relationship payload for the viewer", %{
    alice: profile_user,
    bob: viewer
  } do
    Bonfire.Social.Graph.Follows.follow(viewer, profile_user)

    {:ok, result} =
      Absinthe.run(@query, Schema,
        variables: %{"userId" => profile_user.id, "otherId" => viewer.id},
        context: Schema.context(%{current_user: viewer})
      )

    rel = get_in(result, [:data, "user", "relationship"])
    assert is_map(rel)
    assert rel["following"] == false
    assert rel["followed"] == true
    refute result[:errors]
  end

  test "follow mutation returns the created follow activity and updates relationship", %{
    alice: alice,
    bob: bob
  } do
    {:ok, result} =
      Absinthe.run(@follow_mutation, Schema,
        variables: %{"id" => bob.id, "username" => "unused"},
        context: Schema.context(%{current_user: alice})
      )

    refute result[:errors]
    assert is_binary(get_in(result, [:data, "follow", "id"]))

    {:ok, rel_result} =
      Absinthe.run(@query, Schema,
        variables: %{"userId" => alice.id, "otherId" => bob.id},
        context: Schema.context(%{current_user: alice})
      )

    refute rel_result[:errors]
    assert get_in(rel_result, [:data, "user", "relationship", "following"]) == true
  end

  test "follow mutation returns a GraphQL error instead of null when the domain rejects it", %{
    alice: alice
  } do
    {:ok, result} =
      Absinthe.run(@follow_mutation, Schema,
        variables: %{"id" => alice.id, "username" => "unused"},
        context: Schema.context(%{current_user: alice})
      )

    assert result[:errors]
    assert get_in(result, [:data, "follow"]) == nil
  end

  test "unfollow mutation returns true and clears relationship state", %{alice: alice, bob: bob} do
    {:ok, _follow} = Bonfire.Social.Graph.Follows.follow(alice, bob)

    {:ok, result} =
      Absinthe.run(@unfollow_mutation, Schema,
        variables: %{"id" => bob.id},
        context: Schema.context(%{current_user: alice})
      )

    refute result[:errors]
    assert get_in(result, [:data, "unfollow"]) == true

    {:ok, rel_result} =
      Absinthe.run(@query, Schema,
        variables: %{"userId" => alice.id, "otherId" => bob.id},
        context: Schema.context(%{current_user: alice})
      )

    refute rel_result[:errors]
    assert get_in(rel_result, [:data, "user", "relationship", "following"]) == false
  end

  test "acceptFollowRequest returns true and creates follow state" do
    requester = fake_user!(%{}, %{}, request_before_follow: true)
    recipient = fake_user!(%{}, %{}, request_before_follow: true)

    assert {:ok, _request} = Bonfire.Social.Graph.Follows.follow(requester, recipient)
    assert Bonfire.Social.Graph.Follows.requested?(requester, recipient)

    {:ok, result} =
      Absinthe.run(@accept_follow_request_mutation, Schema,
        variables: %{"id" => requester.id},
        context: Schema.context(%{current_user: recipient})
      )

    refute result[:errors]
    assert get_in(result, [:data, "acceptFollowRequest"]) == true
    assert Bonfire.Social.Graph.Follows.following?(requester, recipient)
    refute Bonfire.Social.Graph.Follows.requested?(requester, recipient)
  end

  test "rejectFollowRequest returns true and clears pending request without following" do
    requester = fake_user!(%{}, %{}, request_before_follow: true)
    recipient = fake_user!(%{}, %{}, request_before_follow: true)

    assert {:ok, _request} = Bonfire.Social.Graph.Follows.follow(requester, recipient)
    assert Bonfire.Social.Graph.Follows.requested?(requester, recipient)

    {:ok, result} =
      Absinthe.run(@reject_follow_request_mutation, Schema,
        variables: %{"id" => requester.id},
        context: Schema.context(%{current_user: recipient})
      )

    refute result[:errors]
    assert get_in(result, [:data, "rejectFollowRequest"]) == true
    refute Bonfire.Social.Graph.Follows.following?(requester, recipient)
    refute Bonfire.Social.Graph.Follows.requested?(requester, recipient)
  end

  test "acceptFollowRequest returns a GraphQL error instead of false for a missing request", %{
    alice: alice,
    bob: bob
  } do
    {:ok, result} =
      Absinthe.run(@accept_follow_request_mutation, Schema,
        variables: %{"id" => bob.id},
        context: Schema.context(%{current_user: alice})
      )

    assert result[:errors]
    assert get_in(result, [:data, "acceptFollowRequest"]) == nil
  end

  test "rejectFollowRequest returns a GraphQL error instead of false for a missing request", %{
    alice: alice,
    bob: bob
  } do
    {:ok, result} =
      Absinthe.run(@reject_follow_request_mutation, Schema,
        variables: %{"id" => bob.id},
        context: Schema.context(%{current_user: alice})
      )

    assert result[:errors]
    assert get_in(result, [:data, "rejectFollowRequest"]) == nil
  end
end
