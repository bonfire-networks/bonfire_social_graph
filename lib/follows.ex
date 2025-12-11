defmodule Bonfire.Social.Graph.Follows do
  @moduledoc """
  Module for handling follow relationships in the Bonfire social graph.
  """

  alias Bonfire.Data.Social.Follow
  alias Bonfire.Data.Social.Request
  alias Bonfire.Data.Edges.Edge

  # alias Bonfire.Me.Boundaries
  alias Bonfire.Me.Characters
  # alias Bonfire.Me.Users

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.FeedActivities
  # alias Bonfire.Social.Feeds
  alias Bonfire.Social
  alias Bonfire.Social.Requests

  # alias Bonfire.Data.Identity.User
  # alias Ecto.Changeset
  # alias Needle.Changesets
  import Bonfire.Boundaries.Queries
  import Untangle
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Follow
  def query_module, do: Follow

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "Follow",
      {"Create", "Follow"},
      {"Undo", "Follow"},
      {"Delete", "Follow"},
      {"Accept", "Follow"},
      {"Reject", "Follow"}
    ]

  @hashtag_table_id "7HASHTAG1SPART0FF01KS0N0MY"

  @doc """
  Checks if a subject is following an object.

  ## Parameters

  - `subject`: The subject (follower)
  - `object`: The object (followed)

  ## Returns

  Boolean indicating if the subject is following the object.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.following?(user, profile)
      true
  """

  # TODO: privacy
  def following?(subject, object),
    # current_user: subject)
    do: Edges.exists?(__MODULE__, subject, object, verbs: [:follow], skip_boundary_check: true)

  @doc """
  Checks if a follow request has been made.

  ## Parameters

  - `subject`: The subject (requester)
  - `object`: The object (requested)

  ## Returns

  Boolean indicating if a follow request exists.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.requested?(user, profile)
      true
  """
  def requested?(subject, object),
    do: Requests.requested?(subject, Follow, object)

  @doc """
  Checks the follow relationship status between a subject and an object.

  ## Parameters

  - `subject`: The subject (follower or requester)
  - `object`: The object (followed or requested)
  - `opts`: Additional options

  ## Returns

  - `Follow` if the subject is following the object
  - `Request` if the subject has requested to follow the object
  - `false` if there is no relationship

  ## Examples

      iex> Bonfire.Social.Graph.Follows.follow_status(user, user2)
      Follow
      
      iex> Bonfire.Social.Graph.Follows.follow_status(user, user3)
      Request
  """
  def follow_status(subject, object, _opts \\ []) do
    follow_table_id = Bonfire.Common.Types.table_id(Follow)

    # Create a single query that checks both Follow and Request tables
    query =
      from e in Edge,
        where: e.subject_id in ^Types.uids(subject) and e.object_id in ^Types.uids(object),
        left_join: f in Follow,
        on: f.id == e.id,
        left_join: r in Request,
        on: r.id == e.id and e.table_id == ^follow_table_id and is_nil(r.ignored_at),
        select: {f.id, r.id},
        limit: 1

    case repo().one(query) do
      {followed, _} when not is_nil(followed) -> Follow
      {_, requested} when not is_nil(requested) -> Request
      _ -> false
    end
  end

  @doc """
  Follows someone or something. In case of success, publishes to feeds and federates.

  If the user is not permitted to follow the object, or the object is
  a remote actor, it will instead send a request to follow.

  ## Parameters

  - `user`: The user who wants to follow
  - `object`: The object to be followed
  - `opts`: Additional options

  ## Returns

  `{:ok, result}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.follow(me, user2)
      {:ok, %Follow{}}

      iex> Bonfire.Social.Graph.Follows.follow(me, user3)
      {:ok, %Request{}}
  """
  def follow(follower, object, opts \\ [])

  def follow(%{} = follower, object, opts) do
    follower = repo().preload(follower, [:character, :peered])
    opts = Keyword.put_new(to_options(opts), :current_user, follower)

    case check_follow(follower, object, opts) do
      {:local, loaded_object} ->
        info("following local, do the follow")
        follow_with_side_effects(follower, loaded_object, opts)

      # Note: we now rely on Boundaries to this instead:
      # if Social.is_local?(follower) do
      #   info("remote following local, attempting a request")
      #   Requests.request(follower, Follow, loaded_object, opts)
      # else
      #   info("local following local, attempting follow")
      #   follow_with_side_effects(follower, loaded_object, opts)
      # end

      {:remote, loaded_object} ->
        if Social.is_local?(follower) do
          info(
            "local following remote, attempting a request instead of follow (which *may* be auto-accepted by the remote instance)"
          )

          Requests.request(follower, Follow, loaded_object, opts)
        else
          warn("remote following remote, we don't record these at the moment")
          {:error, :not_permitted}
        end

      {:error, :not_permitted} ->
        info("not permitted to follow, attempting a request instead")
        Requests.request(follower, Follow, object, opts)
    end
  end

  @doc """
  Follows multiple objects at once, optimizing some operations.

  ## Parameters

  - `follower`: The user who wants to follow
  - `objects`: List of objects to be followed
  - `opts`: Additional options

  ## Returns

  `[{"object1_id", {:ok, result}}, {"object2_id", {:error, msg}}, ...]` 

  ## Examples

      iex> batch_follow(me, [user1, user2])
      [{:ok, %Follow{}, ...], {:ok, %Request{}}]
  """
  def batch_follow(%{} = follower, objects, opts \\ []) when is_list(objects) do
    follower = repo().preload(follower, [:character, :peered])
    opts = Keyword.put_new(to_options(opts), :current_user, follower)

    # Group objects by follow type
    objects_to_action =
      Enum.map(objects, &check_follow(follower, &1, opts))
      |> debug("mapped")
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> debug("objects_to_action")

    # # Handle local follows in bulk
    follows =
      (objects_to_action[:local] || [])
      |> Enum.map(fn object ->
        #  FIXME: don't recompute follower's feed_ids every iteration
        opts_for_object = opts_for_follow(follower, object, opts)
        {id(object), do_follow(follower, object, opts_for_object)}
      end)
      |> do_side_effects(follower, objects, opts)

    # Handle remote follows as requests
    requests =
      (objects_to_action[:remote] || [])
      |> Enum.map(fn object ->
        {id(object), Requests.request(follower, Follow, object, opts)}
      end)

    follows ++ requests
  end

  defp skip_boundary_check_type?(object) do
    types = Application.get_env(:bonfire_social_graph, :skip_boundary_check_types, [])

    Enum.any?(types, fn type ->
      Bonfire.Common.Types.object_type(object) == type
    end)
  end

  defp check_follow(follower, object, opts) do
    # debug(opts)
    # debug(id(follower))
    # debug(id(object))
    skip? = skip_boundary_check?(opts, object)
    # debug(skip?)
    skip? =
      skip? == true ||
        (skip? == :admins and
           maybe_apply(Bonfire.Me.Accounts, :is_admin?, follower, fallback_return: nil) == true) ||
        skip_boundary_check_type?(object)

    opts =
      opts
      |> Keyword.put_new(:verbs, [:follow])
      |> Keyword.put_new(:current_user, follower)
      |> Keyword.put_new(:skip_boundary_check, skip?)

    case uid(object) do
      id when is_binary(id) ->
        case Bonfire.Boundaries.load_pointer(id, opts) |> debug("loaded_pointer") do
          object when is_struct(object) ->
            local_or_remote_object(object)

          _ ->
            {:error, :not_permitted}
        end

      _ ->
        error(object, "no object ID, attempting with username")

        case maybe_apply(Characters, :by_username, [object, opts]) do
          object when is_struct(object) ->
            local_or_remote_object(object)

          _ ->
            {:error, :not_permitted}
        end
    end
  end

  defp opts_for_follow(%{} = follower, %{} = object, opts) do
    to_feeds = [
      # we include follows in feeds, since user has control over whether or not they want to see them in settings
      outbox: [follower],
      notifications: [object]
    ]

    to_feeds_ids = FeedActivities.get_publish_feed_ids(to_feeds)

    Keyword.merge(
      [
        # TODO: make configurable (currently public is required so follows can be listed by AP adapter)
        boundary: "public",
        # also allow the followed user to see it
        to_circles: [id(object)],
        # put it in our outbox and their notifications
        to_feeds: to_feeds,
        # FIXME: should not compute feed ids twice (also done when casting the edge activity)
        to_feeds_ids: to_feeds_ids
      ],
      opts
    )
  end

  defp follow_with_side_effects(%{} = follower, %{} = object, opts) do
    with opts <- opts_for_follow(follower, object, opts),
         {:ok, follow} <- do_follow(follower, object, opts),
         [ok: follow] <- do_side_effects([follow], follower, [object], opts) do
      maybe_apply(Bonfire.Social.LivePush, :push_activity_object, [
        opts[:to_feeds_ids],
        follow,
        object,
        [push_to_thread: false, notify: true]
      ])

      {:ok, follow}
    end
  end

  # Notes for future refactor:
  # * Make it pay attention to options passed in
  # * When we start allowing to follow things that aren't users, we might need to adjust the circles.
  # * Figure out how to avoid the advance lookup and ensuing race condition.
  defp do_follow(%{} = follower, %{} = object, opts) do
    repo().transact_with(fn ->
      case create(follower, object, opts) do
        {:ok, follow} ->
          {:ok, follow}

        e ->
          error(e)
          maybe_already_followed(follower, object)
      end
    end)
  end

  def do_side_effects(follows, follower, objects, opts) do
    # bust the cache for computing feeds
    invalidate_followed_outboxes_cache(id(follower))

    # NOTE: skipping the push for batch follows for now, to avoid spamming feeds
    # to_feed_ids = FeedActivities.get_publish_feed_ids(to_feeds)
    #   if to_feed_ids !=[], do: maybe_apply(Bonfire.Social.LivePush, :push_activity_object, [
    #     to_feed_ids,
    #     follow,
    #     object,
    #     [push_to_thread: false, notify: true]
    #   ])

    ## Batch insert into circles

    follower_type = Types.object_type(follower)

    if follower_type == Bonfire.Data.Identity.User do
      user_objects =
        Enum.filter(objects, fn object ->
          case Types.object_type(object) do
            Bonfire.Data.Identity.User -> true
            _ -> false
          end
        end)

      Bonfire.Boundaries.Circles.add_to_circles(
        objects,
        Bonfire.Boundaries.Circles.get_stereotype_circles(follower, :followed)
      )

      Bonfire.Boundaries.Circles.add_to_circles(
        follower,
        Bonfire.Boundaries.Circles.get_stereotype_circles(
          user_objects,
          :followers
        )
      )

      # insert into graph database
      Bonfire.Social.Graph.graph_add(follower, user_objects, Follow)
    end

    # Handle federation 
    if opts[:incoming] != true do
      Enum.map(follows, fn
        {object_id, {:ok, follow}} ->
          {object_id, Social.maybe_federate_and_gift_wrap_activity(follower, follow)}

        {:ok, %Follow{} = follow} ->
          Social.maybe_federate_and_gift_wrap_activity(follower, follow)

        %Follow{} = follow ->
          Social.maybe_federate_and_gift_wrap_activity(follower, follow)

        other ->
          other
      end)
    else
      Enum.map(follows, fn
        {object_id, {:ok, follow}} ->
          {object_id, follow}

        {:ok, %Follow{} = follow} ->
          {:ok, follow}

        %Follow{} = follow ->
          {:ok, follow}

        other ->
          other
      end)
    end
  end

  @doc """
  Accepts a follow request, publishes to feeds and federates.

  ## Parameters

  - `subject`: The requester
  - `opts`: Additional options including the current user

  ## Returns

  `{:ok, follow}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.accept_from(requester, current_user: acceptor)
      {:ok, %Follow{}}
  """
  def accept_from(subject, opts) do
    Requests.get(subject, Follow, current_user_required!(opts), opts)
    |> debug()
    ~> accept(opts)
  end

  @doc """
  Accepts a follow request, publishes to feeds and federates.

  ## Parameters

  - `request`: A `Request` struct or its ID
  - `opts`: Additional options including the current user

  ## Returns

  `{:ok, follow}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.accept(request, current_user: acceptor)
      {:ok, %Follow{}}
  """
  def accept(request, opts) do
    debug(opts, "opts")

    with {:ok, %{edge: %{object: object, subject: follower}} = request} <-
           Requests.accept_and_delete(request, Follow, opts),
         {:ok, follow} <-
           follow_with_side_effects(follower, object, opts) |> debug("accept_do_follow"),
         :ok <-
           if(opts[:incoming] != true,
             do:
               Requests.ap_publish_activity(
                 e(follow.edge, :object, nil) || follow.edge.object_id,
                 {:accept_to, follower},
                 request
               ),
             else: :ok
           ) do
      {:ok, follow}
    else
      e ->
        error(e, l("An error occurred while accepting the follow request"))
    end
  end

  def reject(follower, followed, opts \\ []) do
    with {:ok, request} <-
           Requests.get(follower, Follow, followed, skip_boundary_check: true),
         {:ok, request} <- ignore(request, opts ++ [current_user: followed]) do
      {:ok, request}
    end
  end

  @doc """
  Unfollows someone or something.

  ## Parameters

  - `user`: The user who wants to unfollow
  - `object`: The object to be unfollowed
  - `opts`: Additional options

  ## Returns

  Result of the unfollow operation.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.unfollow(me, user2)
      {:ok, deleted_follow}
  """
  def unfollow(user, object, opts \\ [])

  def unfollow(user, %{} = object, opts) do
    if following?(user, object) do
      deleted_edges =
        Edges.delete_by_both(user, Follow, object)
        |> debug("deleted")

      # with [_id] <- Edges.delete_by_both(user, Follow, object) do

      # delete the like activity & feed entries
      deleted_activities = Activities.delete_by_subject_verb_object(user, :follow, object)

      invalidate_followed_outboxes_cache(id(user))

      Bonfire.Boundaries.Circles.get_stereotype_circles(user, :followed)
      ~> Bonfire.Boundaries.Circles.remove_from_circles(object, ...)

      Bonfire.Boundaries.Circles.get_stereotype_circles(object, :followers)
      ~> Bonfire.Boundaries.Circles.remove_from_circles(user, ...)

      Bonfire.Social.Graph.graph_remove(user, object, Follow)

      if opts[:incoming] != true,
        do: ap_publish_activity(user, :delete, object),
        else: ok(deleted_edges || deleted_activities)
    else
      if requested?(user, object) do
        Requests.unrequest(user, Follow, object)
      else
        error("Cannot unfollow because not following")
      end
    end
  end

  def unfollow(%{} = user, object, opts) when is_binary(object) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(object,
             current_user: user,
             skip_boundary_check: true
           ) do
      unfollow(user, object, opts)
    end
  end

  @doc """
  Ignores a follow request.

  ## Parameters

  - `request`: The request to ignore
  - `opts`: Additional options

  ## Returns

  Result of the ignore operation.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.ignore(request, current_user: user)
      {:ok, ignored_request}
  """
  def ignore(request, opts) do
    Requests.ignore(request, opts)
  end

  @doc """
  Gets a follow relationship between a subject and an object, if one exists.

  ## Parameters

  - `subject`: The subject (follower)
  - `object`: The object (followed)
  - `opts`: Additional options

  ## Returns

  `{:ok, follow}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.get(user, profile)
      {:ok, %Follow{}}
  """
  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  @doc """
    Gets a follow relationship between a subject and an object, raising an error if not found.
  """
  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  # TODO: abstract the next few functions into Edges

  @doc """
  Lists all follows by a subject.

  ## Parameters

  - `user`: The user whose follows to list
  - `opts`: Additional options

  ## Returns

  List of follows.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.all_by_subject(user)
      [%Follow{}, ...]
  """
  def all_by_subject(user, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :object_character)
    |> query([subjects: user], ...)
    |> repo().many()
  end

  @doc """
  Lists all objects followed by a subject.

  ## Parameters

  - `user`: The user whose followed objects to list
  - `opts`: Additional options

  ## Returns

  List of followed objects.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.all_objects_by_subject(user)
      [%FollowedObject{}, ...]
  """
  def all_objects_by_subject(user, opts \\ []) do
    all_by_subject(user, opts)
    |> Enum.map(&e(&1, :edge, :object, nil))
  end

  @doc """
  Lists all follows for an object.

  ## Parameters

  - `user`: The object whose followers to list
  - `opts`: Additional options

  ## Returns

  List of follows.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.all_by_object(user)
      [%Follow{}, ...]
  """
  def all_by_object(user, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :subject_character)
    |> query([objects: user], ...)
    |> repo().many()
  end

  @doc """
  Lists all subjects following an object.

  ## Parameters

  - `user`: The object whose followers to list
  - `opts`: Additional options

  ## Returns

  List of follower subjects.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.all_subjects_by_object(user)
      [%FollowerSubject{}, ...]
  """
  def all_subjects_by_object(user, opts \\ []) do
    all_by_object(user, opts)
    |> Enum.map(&e(&1, :edge, :subject, nil))
  end

  @doc """
  Lists all followed outboxes for a user.

  ## Parameters

  - `user`: The user whose followed outboxes to list
  - `opts`: Additional options

  ## Returns

  List of followed outbox IDs.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.all_followed_outboxes(user)
      ["outbox_id_1", ...]

      iex> Bonfire.Social.Graph.Follows.all_followed_outboxes(user, include_followed_categories: true)
      ["outbox_id_1", "category_outbox_id_1", ...]
  """

  def all_followed_outboxes(user, opts \\ []) do
    Cache.maybe_apply_cached(
      &fetch_all_followed_outboxes/2,
      [user, opts],
      opts ++ [cache_key: "my_followed:#{opts[:include_followed_categories] == true}:#{id(user)}"]
    )
  end

  defp invalidate_followed_outboxes_cache(user) do
    Cache.remove("my_followed:true:#{id(user)}")
    Cache.remove("my_followed:false:#{id(user)}")
  end

  defp fetch_all_followed_outboxes(user, opts) do
    if(opts[:include_followed_categories] != true,
      do: opts ++ [filters: [exclude_object_types: Bonfire.Classify.Category]],
      else: opts
    )
    |> all_objects_by_subject(user, ...)
    |> debug("fetched followed objects")
    |> Enum.map(
      &(e(&1, :character, :outbox_id, nil) ||
          (e(&1, :table_id, nil) == @hashtag_table_id && id(&1)) || nil)
    )
    |> Enum.reject(&is_nil/1)
  end

  # defp query_base(filters, opts) do
  #   vis = filter_invisible(current_user(opts))
  #   from(f in Follow, join: v in subquery(vis), on: f.id == v.object_id)
  #   |> proload(:edge)
  #   |> query_filter(filters)
  # end

  defp query_base(filters, opts) do
    filters = e(opts, :filters, []) ++ filters

    Edges.query_parent(Follow, filters, opts)
    |> query_filter(Keyword.drop(filters, [:object, :subject]))

    # |> debug("follows query")
  end

  @doc """
  Queries follows based on filters and options.

  ## Parameters

  - `filters`: List of filters to apply to the query
  - `opts`: Additional query options

  ## Returns

  An Ecto query for follows.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.query([my: :objects], current_user: user)
      # following

      iex> Bonfire.Social.Graph.Follows.query([my: :followers], current_user: user)
      # followers
  """
  def query([my: :objects], opts),
    do: query([subjects: current_user_required!(opts)], opts)

  def query([my: :followers], opts),
    do: query([objects: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  @doc """
  Lists followed objects for the current user.

  ## Parameters

  - `current_user`: The current user
  - `opts`: Additional options

  ## Returns

  List of followed objects.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.list_my_followed(current_user)
      [%Object{}, ...]
  """
  def list_my_followed(current_user, opts \\ []),
    do:
      list_followed(
        current_user,
        Keyword.put(to_options(opts), :current_user, current_user)
      )

  @doc """
  Lists followed objects for a given user.

  ## Parameters

  - `user`: The user whose followed objects to list
  - `opts`: Additional options

  ## Returns

  List of followed objects.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.list_followed(user)
      [%Object{}, ...]
  """
  def list_followed(user, opts \\ []) do
    # TODO: configurable boundaries for follows
    opts =
      to_options(opts) ++
        [skip_boundary_check: true, preload: [:object_character, :object_profile]]

    [subjects: uid(user), object_types: opts[:type]]
    |> query(opts)
    |> where([object: object], object.id not in ^e(opts, :exclude_ids, []))
    # |> maybe_with_followed_profile_only(opts)
    |> Social.many(opts[:paginate], opts)
  end

  @doc """
  Lists followers for the current user.

  ## Parameters

  - `current_user`: The current user
  - `opts`: Additional options

  ## Returns

  List of followers.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.list_my_followers(current_user)
      [%User{}, ...]
  """
  def list_my_followers(current_user, opts \\ []),
    do:
      list_followers(
        current_user,
        Keyword.put(to_options(opts), :current_user, current_user)
      )

  @doc """
  Lists followers for a given user.

  ## Parameters

  - `user`: The user whose followers to list
  - `opts`: Additional options

  ## Returns

  List of followers.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.list_followers(user)
      [%User{}, ...]
  """
  def list_followers(user, opts \\ []) do
    opts = to_options(opts) ++ [skip_boundary_check: true, preload: :subject]

    [objects: uid(user), subject_types: opts[:type]]
    |> query(opts)
    |> where([subject: subject], subject.id not in ^e(opts, :exclude_ids, []))
    # |> maybe_with_follower_profile_only(opts)
    |> Social.many(opts[:paginate], opts)
  end

  # defp maybe_with_follower_profile_only(q, true),
  #   do: where(q, [follower_profile: p], not is_nil(p.id))

  # defp maybe_with_follower_profile_only(q, _), do: q

  # def changeset(:create, subject, object, boundary) do
  #   Changesets.cast(%Follow{}, %{}, [])
  #   |> Edges.put_assoc(subject, object, :follow, boundary)
  # end

  # defp local_or_remote_object(id) when is_binary(id) do
  #   Bonfire.Common.Needles.get(id, skip_boundary_check: true)
  #   ~> local_or_remote_object()
  # end
  defp local_or_remote_object(object) do
    object = repo().maybe_preload(object, [:character, :peered, created: [creator: :peered]])

    if Social.is_local?(object) do
      {:local, object}
    else
      {:remote, object}
    end
  end

  defp maybe_already_followed(user, object) do
    case get(user, object, skip_boundary_check: true) do
      {:ok, follow} ->
        debug("the user already follows this object")
        {:ok, follow}

      e ->
        debug("the user DOES NOT already follows this object, check if a request exists")
        Requests.get(user, Follow, object, skip_boundary_check: true)
    end
  end

  defp create(%{} = follower, object, opts) do
    Edges.insert(Follow, follower, :follow, object, opts)
  rescue
    e in Ecto.ConstraintError ->
      error(e)
      maybe_already_followed(follower, object)
  end

  ### ActivityPub integration

  @doc """
  Publishes an ActivityPub activity for a follow-related action.

  ## Parameters

  - `subject`: The subject of the activity
  - `verb`: The verb of the activity (e.g., :delete)
  - `follow`: The follow object or ID

  ## Returns

  `{:ok, activity}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.ap_publish_activity(user, :delete, follow)
      {:ok, %ActivityPub.Activity{}}
  """
  def ap_publish_activity(subject, :delete, %Follow{edge: edge}) do
    ap_publish_activity(
      subject || e(edge, :subject, nil) || edge.subject_id,
      :delete,
      e(edge, :object, nil) || edge.object_id
    )
  end

  def ap_publish_activity(subject, :delete, object) do
    with {:ok, follower} <-
           ActivityPub.Actor.get_cached(pointer: subject),
         {:ok, ap_object} <-
           ActivityPub.Actor.get_cached(pointer: object) do
      ActivityPub.unfollow(%{actor: follower, object: ap_object, local: true})
    end
  end

  def ap_publish_activity(subject, _verb, follow) do
    error_msg = l("Could not federate the follow")

    follow = repo().maybe_preload(follow, :edge)

    with {:ok, follower} <-
           ActivityPub.Actor.get_cached(
             pointer:
               subject || e(follow, :edge, :subject, nil) || e(follow, :edge, :subject_id, nil)
           )
           |> info("follower actor"),
         {:ok, object} <-
           ActivityPub.Actor.get_cached(
             pointer: e(follow.edge, :object, nil) || e(follow, :edge, :object_id, nil)
           )
           |> info("followed actor"),
         {:ok, activity} <-
           ActivityPub.follow(%{
             actor: follower,
             object: object,
             local: true,
             pointer: uid(follow)
           }) do
      {:ok, activity}
    else
      {:error, :not_found} ->
        error("Actor not found", error_msg)
        {:ok, :ignore}

      {:reject, reason} ->
        {:reject, reason}

      e ->
        error(e, error_msg)
        raise error_msg
    end
  end

  @doc """
  Receives and processes an ActivityPub activity related to follows.

  ## Parameters

  - `follower`: The follower
  - `activity`: The ActivityPub activity
  - `object`: The object of the activity

  ## Returns

  `{:ok, result}` on success, `{:ignore, reason}` on failure or when ignored.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.ap_receive_activity(follower, activity, object)
      {:ok, %Follow{}}
  """
  def ap_receive_activity(
        follower,
        %{data: %{"type" => "Follow"} = data} = _activity,
        object
      )
      when is_binary(follower) or is_struct(follower) do
    info(data, "Follows: attempt to record an incoming follow...")

    with {:ok, followed} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(object),
         # check if not already following
         false <- following?(follower, followed),
         {:ok, %Follow{} = follow} <-
           follow(follower, followed, current_user: follower, incoming: true) |> debug("fffff") do
      with {:ok, _} = accept <-
             ActivityPub.accept(%{
               actor: object,
               to: [data["actor"]],
               object: data,
               local: true
             }) do
        debug(accept, "Follow was auto-accepted")

        {:ok, follow}
      else
        e ->
          error(e, "Unable to auto-accept the follow")
          {:ok, follow}
      end
    else
      true ->
        warn("Federated follow already exists")
        # reaffirm that the follow has gone through when following? was already == true

        ActivityPub.accept(%{
          actor: object,
          to: [data["actor"]],
          object: data,
          local: true
        })

      {:ok, %Request{} = request} ->
        info("Follow was requested and remains pending")
        {:ok, request}

      e ->
        error(e, "Could not follow")
        {:ignore, "Could not follow"}
    end
  end

  def ap_receive_activity(
        followed,
        %{data: %{"type" => "Accept"} = _data} = _activity,
        %{data: %{"actor" => ap_follower}} = _object
      ) do
    info(followed, "Accept incoming request")

    with {:ok, follower} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(ap_follower) do
      with {:ok, request} <-
             Requests.get(follower, Follow, followed, skip_boundary_check: true),
           {:ok, accepted} <- accept(request, current_user: followed, incoming: true) do
        debug(accepted, "acccccepted")
        {:ok, accepted}
      else
        {:error, :not_found} ->
          case following?(follower, followed) do
            false ->
              error("No such Follow")

            true ->
              # already followed
              {:ok, nil}
          end

        e ->
          error(e)
      end
    else
      {:error, :not_found} ->
        error(ap_follower, "No actor found for the follower")

      e ->
        error(e)
    end
  end

  def ap_receive_activity(
        followed,
        %{data: %{"type" => "Reject"} = _data} = _activity,
        %{data: %{"actor" => follower}} = _object
      ) do
    with {:ok, follower} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(follower) do
      case following?(follower, followed) do
        false ->
          reject(follower, followed, incoming: true)

        true ->
          request =
            with {:ok, request} <- reject(follower, followed, incoming: true) do
              request
              |> debug("rejected previously accepted request")
            end

          unfollow(follower, followed, incoming: true)
          |> debug("unfollow rejected follow")

          {:ok, request}
      end
    end
  end

  def ap_receive_activity(
        follower,
        %{data: %{"type" => "Undo"} = _data} = _activity,
        %{data: %{"object" => followed_ap_id}} = _object
      ) do
    with {:ok, object} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(
             followed_ap_id
           ),
         [id] <- unfollow(follower, object, incoming: true) do
      {:ok, id}
    end
  end
end
