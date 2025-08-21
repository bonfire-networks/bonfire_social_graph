defmodule Bonfire.Social.Graph.Import do
  use Oban.Worker,
    #  TODO: sort out queue vs op
    queue: :import,
    max_attempts: 1

  use Arrows

  alias NimbleCSV.RFC4180, as: CSV

  import Untangle
  # alias Bonfire.Data.Identity.User
  # alias Bonfire.Me.Characters
  alias Bonfire.Common.Utils
  alias Bonfire.Me.Users
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @doc """
  Import follows, ghosts, silences, or blocks from a CSV file.

  ## Examples

      iex> import_from_csv_file(:following, scope, "path/to/file.csv")

  """
  def import_from_csv_file(:following, scope, path), do: follows_from_csv_file(scope, path)
  def import_from_csv_file(:ghosts, scope, path), do: ghosts_from_csv_file(scope, path)
  def import_from_csv_file(:silences, scope, path), do: silences_from_csv_file(scope, path)
  def import_from_csv_file(:blocks, scope, path), do: blocks_from_csv_file(scope, path)
  def import_from_csv_file(:bookmarks, scope, path), do: bookmarks_from_csv_file(scope, path)
  def import_from_csv_file(:circles, scope, path), do: circles_from_csv_file(scope, path)

  def import_from_csv_file(_other, _user, _path),
    do: error("Please select a valid type of import")

  defp follows_from_csv_file(scope, path) do
    follows_from_csv(scope, read_file(path))
    # TODO: delete file
  end

  defp follows_from_csv(scope, csv) do
    process_csv("follows_import", scope, csv)
  end

  defp ghosts_from_csv_file(scope, path) do
    ghosts_from_csv(scope, read_file(path))
    # TODO: delete file
  end

  defp ghosts_from_csv(scope, csv) do
    process_csv("ghosts_import", scope, csv)
  end

  defp silences_from_csv_file(scope, path) do
    silences_from_csv(scope, read_file(path))
    # TODO: delete file
  end

  defp silences_from_csv(scope, csv) do
    process_csv("silences_import", scope, csv)
  end

  defp blocks_from_csv_file(scope, path) do
    blocks_from_csv(scope, read_file(path))
    # TODO: delete file
  end

  defp blocks_from_csv(scope, csv) do
    process_csv("blocks_import", scope, csv)
  end

  defp bookmarks_from_csv_file(scope, path) do
    bookmarks_from_csv(scope, read_file(path))
  end

  defp bookmarks_from_csv(scope, csv) do
    process_csv("bookmarks_import", scope, csv, false)
  end

  defp circles_from_csv_file(scope, path) do
    circles_from_csv(scope, read_file(path))
  end

  defp circles_from_csv(scope, csv) do
    process_csv("circles_import", scope, csv, false)
  end

  defp read_file(path) do
    path
    |> File.read!()

    # |> File.stream!(read_ahead: 100_000) # FIXME?
  end

  defp process_csv(type, scope, csv, with_header \\ true)

  defp process_csv("circles_import" = type, scope, csv, with_header) when is_binary(csv) do
    case csv
         |> CSV.parse_string(skip_headers: with_header) do
      # for cases where its a simple text file
      [] -> [[csv]]
      csv -> csv
    end
    |> debug()
    # For circles, we need both columns: circle_name,username
    |> Enum.map(fn row ->
      case row do
        [circle_name, username] ->
          {String.trim(circle_name), String.trim(username) |> String.trim_leading("@")}

        [single_value] ->
          # If only one column, skip this row as it's invalid
          nil

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == {"", ""}))
    |> enqueue_many(type, scope, ...)
  end

  defp process_csv(type, scope, csv, with_header) when is_binary(csv) do
    case csv
         #  |> debug()
         |> CSV.parse_string(skip_headers: with_header) do
      # for cases where its a simple text file
      [] -> [[csv]]
      csv -> csv
    end
    |> debug()
    # |> List.delete("Account address")
    |> Enum.map(&(&1 |> List.first() |> String.trim() |> String.trim_leading("@")))
    |> Enum.reject(&(&1 == ""))
    |> enqueue_many(type, scope, ...)
  end

  defp process_csv("circles_import" = type, scope, csv, with_header) do
    # using Stream for circles with two columns
    csv
    |> CSV.parse_stream(skip_headers: with_header)
    |> Stream.map(fn data_cols ->
      case data_cols do
        [circle_name, username] ->
          enqueue_many(
            type,
            scope,
            {String.trim(circle_name), String.trim(username) |> String.trim_leading("@")}
          )

        _ ->
          # Skip invalid rows
          {:ok, %{errors: ["Invalid format"]}}
      end
    end)
    |> results_return()
  end

  #  for any other types that have a single (relevant) column
  defp process_csv(type, scope, csv, with_header) do
    # using Stream
    csv
    |> CSV.parse_stream(skip_headers: with_header)
    |> Stream.map(fn data_cols ->
      enqueue_many(
        type,
        scope,
        data_cols
        |> List.first()
        |> String.trim()
        |> String.trim_leading("@")
        # |> debug()
      )
    end)
    |> results_return()
  end

  # def follows_from_list(%User{} = follower, [_ | _] = identifiers) do
  #   enqueue_many("follows_import", follower, identifiers)
  # end

  # def ghosts_from_list(%User{} = ghoster, [_ | _] = identifiers) do
  #   enqueue_many("ghosts_import", ghoster, identifiers)
  # end

  # def silences_from_list(%User{} = scope, [_ | _] = identifiers) do
  #   enqueue_many("silences_import", scope, identifiers)
  # end

  # def blocks_from_list(%User{} = scope, [_ | _] = identifiers) do
  #   enqueue_many("blocks_import", scope, identifiers)
  # end

  defp enqueue_many(op, scope, identifiers) when is_list(identifiers) do
    identifiers
    |> Enum.map(fn identifier ->
      enqueue(op, scope, identifier)
    end)
    |> results_return()
  end

  defp enqueue_many(op, scope, identifier) do
    enqueue(op, scope, identifier)
    |> List.wrap()
    |> results_return()
  end

  defp enqueue(op, scope, {circle_name, username}),
    do:
      job_enqueue([queue: :import], %{
        "op" => op,
        "user_id" => scope,
        "context" => circle_name,
        "identifier" => username
      })

  defp enqueue(op, scope, identifier),
    do:
      job_enqueue([queue: :import], %{"op" => op, "user_id" => scope, "identifier" => identifier})

  defp job_enqueue(spec, worker_args \\ []), do: job(spec, worker_args) |> Oban.insert()

  defp job(spec, worker_args \\ []), do: new(worker_args, spec)

  defp results_return(results) do
    results
    |> Enum.frequencies_by(fn
      {:ok, %{errors: errors}} when is_list(errors) and errors != [] ->
        error(errors, "import error")
        :error

      {:ok, result} ->
        debug(result, "import result")
        :ok

      other ->
        error(other, "import error")
        :error
    end)
  end

  @doc """
  Perform the queued job based on the operation and scope.

  ## Examples

      iex> perform(%{args: %{"op" => "follows_import", "user_id" => "user1", "identifier" => "id1"}})
      :ok

      iex> perform(%{args: %{"op" => "blocks_import", "user_id" => "instance_wide", "identifier" => "id1"}})
      :ok

  """
  def perform(%{
        args: %{"op" => op, "user_id" => "instance_wide", "identifier" => identifier} = _args
      }) do
    # debug(args, op)
    perform(op, identifier, :instance_wide)
  end

  def perform(%{
        args:
          %{
            "op" => "circles_import",
            "user_id" => user_id,
            "context" => circle_name,
            "identifier" => username
          } = _args
      }) do
    with {:ok, user} <- Users.by_username(user_id) do
      perform("circles_import", {circle_name, username}, current_user: user)
    end
  end

  def perform(%{args: %{"op" => op, "user_id" => user_id, "identifier" => identifier} = _args}) do
    # debug(args, op)
    with {:ok, user} <- Users.by_username(user_id) do
      perform(op, identifier, current_user: user)
    end
  end

  @doc """
  Perform an import operation for the scope.

  ## Examples

      iex> perform("follows_import", scope, "identifier")

  """
  def perform("silences_import" = op, identifier, scope) do
    with {:ok, %{} = silence} <-
           AdapterUtils.get_by_url_ap_id_or_username(identifier,
             add_all_domains_as_instances: true
           ),
         {:ok, _silenced} <- Blocks.block(silence, [:silence], scope) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("ghosts_import" = op, identifier, scope) do
    with {:ok, %{} = ghost} <-
           AdapterUtils.get_by_url_ap_id_or_username(identifier,
             add_all_domains_as_instances: true
           ),
         {:ok, _ghosted} <- Blocks.block(ghost, [:ghost], scope) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("blocks_import" = op, identifier, scope) do
    with {:ok, %{} = ghost} <-
           AdapterUtils.get_by_url_ap_id_or_username(identifier,
             add_all_domains_as_instances: true
           ),
         {:ok, _blocked} <- Blocks.block(ghost, [:ghost, :silence], scope) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("follows_import" = op, identifier, scope) do
    with {:ok, %{} = followed} <- AdapterUtils.get_by_url_ap_id_or_username(identifier),
         {:ok, _followed} <- Follows.follow(Utils.current_user(scope), followed) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("bookmarks_import" = op, identifier, scope) do
    with {:ok, %{} = bookmarkable} <-
           AdapterUtils.get_or_fetch_and_create_by_uri(identifier,
             add_all_domains_as_instances: true
           ),
         {:ok, _bookmark} <-
           Bonfire.Social.Bookmarks.bookmark(Utils.current_user(scope), bookmarkable) do
      :ok
    else
      error -> handle_error(op, identifier, error)
    end
  end

  def perform("circles_import" = op, {circle_name, username}, scope) do
    with {:ok, user} <- AdapterUtils.get_by_url_ap_id_or_username(username),
         {:ok, circle} <-
           Bonfire.Boundaries.Circles.get_or_create(circle_name, Utils.current_user(scope)),
         {:ok, _encircle} <- Bonfire.Boundaries.Circles.add_to_circles(user, circle) do
      :ok
    else
      error -> handle_error(op, "#{circle_name}; #{username}", error)
    end
  end

  def perform(_, _, _), do: :ok

  defp handle_error(op, identifier, {:error, error}) do
    handle_error(op, identifier, error)
  end

  defp handle_error(_op, _identifier, error) when is_binary(error) or is_atom(error) do
    error(error)
  end

  defp handle_error(op, identifier, error) do
    error(error, "#{op} failed for #{identifier}")
  end
end
