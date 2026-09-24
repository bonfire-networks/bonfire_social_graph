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

      # the accepted follow's activity must show the FOLLOWER as the actor — not the accepter.
      # Regression for bonfire-app#1907/#1906/#1659 (the activity was created with subject =
      # current_user, i.e. the accepter, so notifications showed the wrong/invalid actor).
      assert %{edges: edges} =
               Bonfire.Social.FeedLoader.feed(:notifications,
                 current_user: followed,
                 preload: false
               )

      follow_verb_id = Bonfire.Boundaries.Verbs.get(:follow)[:id]

      follow_activity =
        Enum.find_value(edges, fn e ->
          if e.activity.verb_id == follow_verb_id, do: e.activity
        end)

      assert follow_activity, "expected a :follow activity in the followed user's notifications"

      assert follow_activity.subject_id == follower.id,
             "accepted follow's subject should be the follower (#{follower.id}), got #{follow_activity.subject_id} (accepter is #{followed.id})"
    end

    test "can accept a follow request given only its id, as the Accept button does", %{
      follower: follower,
      followed: followed
    } do
      # the LiveView Accept button only sends `phx-value-id`, so the request is looked up by id
      # rather than handed over as a struct (which `Requests.requested/2` short-circuits) — this
      # is the one divergence between the passing struct-based test above and the failing UI
      # reported against an instance with federation OFF (tests default it ON, config/test.exs)
      Process.put(:federating, false)

      {:ok, request} = Bonfire.Social.Graph.Follows.follow(follower, followed)
      assert Bonfire.Social.Graph.Follows.requested?(follower, followed)

      assert {:ok, _follow} =
               Bonfire.Social.Graph.Follows.accept(request.id, current_user: followed)

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

  # A notification's Accept button sends every kind of ask to `Follows.accept/2` by id. A kind it knows is handed on to what accepts it (the join case is in `bonfire_classify`'s groups tests), and anything else is refused while still pending, rather than being turned into a follow
  describe "accepting a request that is not a follow request" do
    test "a quote request is handed on and the quote accepted" do
      alice = fake_user!()
      bob = fake_user!()

      {:ok, quoted} =
        Bonfire.Posts.publish(
          current_user: alice,
          boundary: "public",
          post_attrs: %{post_content: %{html_body: "to be quoted"}}
        )

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: bob,
          boundary: "public",
          quotes: [quoted],
          post_attrs: %{post_content: %{html_body: "quoting"}}
        )

      assert {:ok, request} = Bonfire.Social.Quotes.requested(post, quoted)
      opts = [current_user: alice]
      assert Bonfire.Social.Quotes.count([in_thread: quoted.id], opts) == 0, "control: pending"

      assert {:ok, _} = Bonfire.Social.Graph.Follows.accept(request.id, opts)

      assert Bonfire.Social.Quotes.count([in_thread: quoted.id], opts) == 1
    end

    test "a kind it does not know is refused and stays pending" do
      asker = fake_user!()
      followed = fake_user!(%{}, %{}, request_before_follow: true)
      like_verb = Bonfire.Boundaries.Verbs.get_id!(:like)

      assert {:ok, request} = Bonfire.Social.Requests.request(asker, like_verb, followed)

      assert {:error, _} =
               Bonfire.Social.Graph.Follows.accept(request.id, current_user: followed)

      assert Bonfire.Social.Requests.requested?(asker, like_verb, followed),
             "a refusal must leave the ask pending, since the caller is told it failed"

      refute Bonfire.Social.Graph.Follows.following?(asker, followed)

      {:ok, follow_request} = Bonfire.Social.Graph.Follows.follow(asker, followed)

      assert {:ok, _} =
               Bonfire.Social.Graph.Follows.accept(follow_request.id, current_user: followed),
             "control: the same call accepts a follow request, so the refusal above is about the kind"
    end
  end

  # Asking to follow is gated by the `:request` verb, so denying it has to actually stop the request being created. `Follows.follow/3` reaches `Requests.request/4` down its `:not_permitted` path, which is the same path an ordinary locked account takes, so the check belongs there rather than in the caller. The pair below has to be read together: "no request was created" and "the request path never ran" look identical from the outside.
  describe "being denied the ask" do
    test "an ordinary account can ask to follow a locked account" do
      followed = fake_user!(%{}, %{}, request_before_follow: true)
      asker = fake_user!()

      assert {:ok, _} = Bonfire.Social.Graph.Follows.follow(asker, followed)

      assert Bonfire.Social.Graph.Follows.requested?(asker, followed),
             "the control: asking works by default, so the refusal below is about the denial rather than about locked accounts being unaskable"
    end

    test "an account denied :request cannot ask to follow" do
      followed = fake_user!(%{}, %{}, request_before_follow: true)
      denied = fake_user!()

      Bonfire.Boundaries.Controlleds.grant_role(denied.id, followed, :cannot_request,
        current_user: followed
      )

      Bonfire.Social.Graph.Follows.follow(denied, followed)

      refute Bonfire.Social.Graph.Follows.requested?(denied, followed),
             "`cannot_request` is the only way to say \"do not ask me\", so a request row here means the denial has no effect"

      refute Bonfire.Social.Graph.Follows.following?(denied, followed)
    end
  end
end
