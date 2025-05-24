defmodule Bonfire.Social.Graph.FollowRequestsTest do
  use Bonfire.DataCase, async: true

  describe "follow requests" do
    setup do
      follower = fake_user!(%{}, %{}, request_before_follow: true)
      followed = fake_user!(%{}, %{}, request_before_follow: true)

      %{
        follower: follower,
        followed: followed
      }
    end

    test "can request to follow a user who requires request confirmation before being followed, who will see it in notifications and can accept it",
         %{follower: follower, followed: followed} do
      # Send follow request
      {:ok, request} = Bonfire.Social.Graph.Follows.follow(follower, followed)

      # Check that a request was created, not a direct follow
      assert Bonfire.Social.Graph.Follows.requested?(follower, followed)
      refute Bonfire.Social.Graph.Follows.following?(follower, followed)

      assert %{edges: [notification | _]} =
               Bonfire.Social.FeedLoader.feed(:notifications,
                 current_user: followed,
                 preload: false
               )

      assert notification.activity.object_id == followed.id

      assert %{edges: [notification | _]} =
               Bonfire.Social.FeedLoader.feed(:my, current_user: followed, preload: false)

      assert notification.activity.object_id == followed.id

      # assert  %{edges: [notification | _]} = Bonfire.Social.FeedLoader.feed(:explore, request, current_user: followed, preload: false)
      # assert notification.activity.object_id == followed.id

      assert %{edges: []} = Bonfire.Social.FeedLoader.feed(:explore, preload: false)

      assert %{edges: []} =
               Bonfire.Social.FeedLoader.feed(:explore, request,
                 current_user: follower,
                 preload: false
               )

      # The followed user accepts the request
      {:ok, follow} = Bonfire.Social.Graph.Follows.accept(request, current_user: followed)

      # Now the follow relationship should be established
      assert Bonfire.Social.Graph.Follows.following?(follower, followed)
      refute Bonfire.Social.Graph.Follows.requested?(follower, followed)
    end

    test "can ignore a follow request", %{follower: follower, followed: followed} do
      # Create a follow request
      {:ok, request} = Bonfire.Social.Graph.Follows.follow(follower, followed)

      # Verify request exists
      assert Bonfire.Social.Graph.Follows.requested?(follower, followed)

      # Recipient ignores the request
      {:ok, _ignored} = Bonfire.Social.Graph.Follows.ignore(request, current_user: followed)

      refute Bonfire.Social.Graph.Follows.following?(follower, followed)
      refute Bonfire.Social.Graph.Follows.requested?(follower, followed)
    end

    test "can list follow requests I've sent or received", %{
      follower: follower,
      followed: followed
    } do
      # Create follow requests
      {:ok, _request1} = Bonfire.Social.Graph.Follows.follow(follower, followed)
      {:ok, _request2} = Bonfire.Social.Graph.Follows.follow(follower, followed)

      # List requests sent by follower
      requests = Bonfire.Social.Requests.list_my_requested(current_user: follower)

      # Request recipients should match
      recipient_ids = Enum.map(requests, fn req -> req.edge.object_id end)
      assert Enum.member?(recipient_ids, followed.id)

      # List requests received by followed
      requesters = Bonfire.Social.Requests.list_my_requesters(current_user: followed)

      # Requesters should match
      requester_ids = Enum.map(requesters, fn req -> req.edge.subject_id end)
      assert Enum.member?(requester_ids, follower.id)
    end
  end
end
