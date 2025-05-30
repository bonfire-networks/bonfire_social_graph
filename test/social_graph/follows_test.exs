defmodule Bonfire.Social.Graph.FollowsTest do
  use Bonfire.Social.Graph.DataCase, async: true

  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Social.Bonfire.Social.FeedLoader

  alias Bonfire.Me.Fake

  test "can follow" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, %{edge: edge} = follow} = Follows.follow(me, followed)
    # debug(follow)
    # debug(activity)
    assert edge.subject_id == me.id
    assert edge.object_id == followed.id
  end

  test "can batch follow" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    followed2 = Fake.fake_user!()
    id = id(followed)
    id2 = id(followed)

    assert [{id, {:ok, %{edge: edge}}}, {id2, {:ok, %{edge: edge2}}}] =
             Follows.batch_follow(me, [followed, followed2])

    # debug(follow)
    # debug(activity)
    assert edge.subject_id == me.id
    assert edge.object_id == followed.id
    assert edge2.object_id == followed2.id
  end

  test "can get my follow, ignoring boundary checks" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    assert {:ok, fetched_follow} = Follows.get(me, followed, skip_boundary_check: true)

    assert fetched_follow.id == follow.id
  end

  test "can get my follow" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    assert {:ok, fetched_follow} = Follows.get(me, followed)

    assert fetched_follow.id == follow.id
  end

  test "can check if I am following someone or not" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert false == Follows.following?(me, followed)

    assert {:ok, follow} = Follows.follow(me, followed)

    assert true == Follows.following?(me, followed)
  end

  test "can unfollow someone" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    Follows.unfollow(me, followed)
    assert false == Follows.following?(me, followed)
  end

  test "can list my followed" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    assert %{edges: [fetched_follow]} = Follows.list_my_followed(me)

    assert fetched_follow.id == follow.id
  end

  test "can list my followers, ignoring boundaries" do
    me = Fake.fake_user!()
    follower = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(follower, me)

    assert %{edges: [fetched_follow]} = Follows.list_my_followers(me, skip_boundary_check: true)

    assert fetched_follow.id == follow.id
  end

  test "can list my followers, with boundaries enforced" do
    me = Fake.fake_user!()
    follower = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(follower, me)

    assert %{edges: [fetched_follow]} = Follows.list_my_followers(me)

    assert fetched_follow.id == follow.id
  end

  test "can list someone's followers and followed" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, someone)

    assert %{edges: [fetched_follow]} = Follows.list_followers(someone, current_user: me)

    assert fetched_follow.id == follow.id

    assert %{edges: [fetched_follow]} = Follows.list_followers(someone, current_user: me)

    assert fetched_follow.id == follow.id
  end

  # because follows are being excluded from the feed query
  test "follow appears in followed's notifications" do
    follower = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(follower, followed)

    assert %{edges: [fetched_follow]} = Follows.list_followers(followed, current_user: follower)

    assert fetched_follow.id == follow.id

    assert %{edges: [notification | _]} =
             Bonfire.Social.FeedLoader.feed(:notifications, current_user: followed)

    assert notification.activity.object_id == followed.id

    # assert activity = repo().maybe_preload(notification.activity, object: [:profile])

    # debug(followed: followed)
    # debug(notifications: activity)
  end
end
