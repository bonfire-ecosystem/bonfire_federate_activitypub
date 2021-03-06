defmodule Bonfire.Federate.ActivityPub.Receiver do
  require Logger
  alias Bonfire.Search.Indexer
  alias Bonfire.Common.Utils
  alias Bonfire.Federate.ActivityPub.Adapter

  # the following constants are derived from config, so please make any changes/additions there

  @actor_types Bonfire.Common.Config.get([Bonfire.Federate.ActivityPub.Adapter, :actor_types], ["Person", "Group", "Application", "Service", "Organization"])

  def receive_activity(activity_id) when is_binary(activity_id) do
    log("AP - load the activity data")
    ActivityPub.Object.get_by_id(activity_id)
    |> receive_activity()
  end

  def receive_activity(activity) when not is_map_key(activity, :data) do
    log("AP - case when the worker gives us an activity")
    receive_activity(%{data: activity})
  end

  def receive_activity(
        %{
          data: %{
            "object" => object_id
          }
        } = activity
      ) when is_binary(object_id) do
    log("AP - load the object data")
    object = Bonfire.Federate.ActivityPub.Utils.get_object_or_actor_by_ap_id!(object_id)

    #IO.inspect(activity: activity)
    #IO.inspect(object: object)

    receive_activity(activity, object)
  end

  def receive_activity(
        %{
          data: %{
            "object" => object
          }
        } = activity
      ) do
    log("AP - case #1 when the object comes to us embeded in the activity")

    #IO.inspect(activity: activity)
    #IO.inspect(object: object)

    receive_activity(activity, object)
  end

  def receive_activity(activity, object) when not is_map_key(object, :data) do
    log("AP - case #2 when the object comes to us embeded in the activity")
    receive_activity(activity, %{data: object})
  end

  # Activity: Update + Object: actor/character
  def receive_activity(
        %{data: %{"type" => "Update"}} = _activity,
        %{data: %{"type" => object_type, "id" => ap_id}} = _object
      )
      when object_type in @actor_types do
    log("AP Match#0 - update actor")

    with {:ok, actor} <- ActivityPub.Actor.get_cached_by_ap_id(ap_id),
         {:ok, actor} <- Bonfire.Federate.ActivityPub.Adapter.update_remote_actor(actor) do
      # Indexer.maybe_index_object(actor)
      :ok
    end
  end

  def receive_activity(
        %{
          data: %{
            "type" => activity_type
          }
        } = activity,
        %{data: %{"type" => object_type}} = object
      )
      when is_binary(activity_type) and is_binary(object_type) do

    log(
      "AP Match#1 - with activity_type and object_type: #{activity_type} & #{object_type}"
    )

    with {:ok, actor} <- activity_character(activity),
        {:error, _} <-
            handle_activity_with(
              Bonfire.Federate.ActivityPub.FederationModules.federation_module({activity_type, object_type}),
              actor,
              activity,
              object
            ),
        {:error, _} <-
            handle_activity_with(
              Bonfire.Federate.ActivityPub.FederationModules.federation_module(activity_type),
              actor,
              activity,
              object
            ),
        {:error, _} <-
            handle_activity_with(
              Bonfire.Federate.ActivityPub.FederationModules.federation_module(object_type),
              actor,
              activity,
              object
            ) do
      receive_activity_fallback(activity, object, actor)
    end
  end

  def receive_activity(
      %{
        data: %{
          "type" => activity_type
        }
      } = activity,
      object
    )
    when is_binary(activity_type) do
      log(
        "AP Match#2 - by activity_type only: #{activity_type}"
      )

      with {:ok, actor} <- activity_character(activity),
        {:error, _} <-
          handle_activity_with(
            Bonfire.Federate.ActivityPub.FederationModules.federation_module(activity_type),
            actor,
            activity,
            object
          ) do
      receive_activity_fallback(activity, object, actor)
    end
  end

  def receive_activity(
        activity,
        %{data: %{"type" => object_type}} = object
      )
      when is_binary(object_type) do
    log(
      "AP Match#3 - by object_type only: #{object_type}"
    )

    with {:ok, actor} <- activity_character(activity),
        {:error, _} <-
            handle_activity_with(
              Bonfire.Federate.ActivityPub.FederationModules.federation_module(object_type),
              actor,
              activity,
              object
            ) do
      receive_activity_fallback(activity, object, actor)
    end
  end


  def receive_activity(activity, object) do
    receive_activity_fallback(activity, object)
  end

  defp receive_activity_fallback(activity, object, actor \\ nil) do
    # TODO save this as an Activity so it can be displayed in feeds using the JSON
    error = "ActivityPub - ignored incoming activity - unhandled activity or object type"
    Logger.error("#{error}")
    log("AP activity: #{inspect(activity, pretty: true)}")
    log("AP object: #{inspect(object, pretty: true)}")
    {:error, error}
  end


  defp handle_activity_with({:ok, module}, character, activity, object)
    when is_atom(module) and not is_nil(module) do
    log("AP - handle_activity_with: #{module}")

    with {:ok, %{id: pointable_object_id} = pointable_object} <- Utils.maybe_apply(
      module,
      :ap_receive_activity,
      [character, activity, object],
      &error/2
    ) do

      Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(pointable_object_id, object.data["id"])

      if !Map.get(activity, :pointer_id) && Map.get(pointable_object, :activity), do: ActivityPub.Object.update(activity, %{pointer_id: Map.get(pointable_object.activity, :id)}) # necessary?

      if !Map.get(object, :pointer_id), do: ActivityPub.Object.update(object, %{pointer_id: pointable_object_id})

      {:ok, pointable_object}
    end
  end

  # defp handle_activity_with(_module, {:error, _}, activity, _) do
  #   error("AP - could not find local character for the actor", activity)
  # end

  defp handle_activity_with(_module, _actor, _activity, _object) do
    log("AP - no module defined to handle_activity_with")
    {:error, :skip}
  end

  def activity_character(%{data: %{"actor" => %{"id" => actor}}} = _activity) do
    activity_character(actor)
  end

  def activity_character(%{data: %{"actor" => actor}} = _activity) do
    activity_character(actor)
  end

  def activity_character(actor) when is_binary(actor) do
    # FIXME to handle actor types other than Person/User
    with {:error, :not_found} <- Adapter.character_module("Person").by_ap_id(actor) do
      error("AP - could not find local character for the actor", actor)
    end
  end

  @deprecated "Define in host application context modules instead"
  def create_remote_character(actor, username) do

    peer = Bonfire.Federate.ActivityPub.Peers.get_or_create(actor)

    name =
      case actor["name"] do
        nil -> actor["preferredUsername"]
        "" -> actor["preferredUsername"]
        _ -> actor["name"]
      end

    icon_url = Bonfire.Federate.ActivityPub.Utils.maybe_fix_image_object(actor["icon"])
    image_url = Bonfire.Federate.ActivityPub.Utils.maybe_fix_image_object(actor["image"])

    create_attrs = %{
      preferred_username: username,
      name: name,
      summary: actor["summary"],
      is_public: true,
      is_local: false,
      is_disabled: false,
      peer_id: peer.id,
      canonical_url: actor["id"]
    }

    {:ok, created_character, creator} =
      case actor["type"] do
        "Person" ->
          {:ok, created_character} = Bonfire.Me.Users.ActivityPub.create(create_attrs)
          {:ok, created_character, created_character}

        "Organization" ->
            {:ok, created_character} = Bonfire.Me.SharedUsers.create(create_attrs, :remote) # TODO
            {:ok, created_character, created_character}

        # "Group" ->
        #   {:ok, creator} =
        #     Bonfire.Federate.ActivityPub.Utils.get_raw_character_by_ap_id(actor["attributedTo"])

        #   {:ok, created_character} = Bonfire.Groups.create(creator, create_attrs, :remote) # FIXME when we have Groups
        #   {:ok, created_character, creator}

        _ ->
          {:ok, creator} =
            Bonfire.Federate.ActivityPub.Utils.get_raw_character_by_ap_id(actor["attributedTo"])

          {:ok, created_character} =
            Bonfire.Me.Characters.create(creator, create_attrs, :remote) # TODO as fallback

          {:ok, created_character, creator}
      end

    icon_id = Bonfire.Federate.ActivityPub.Utils.maybe_create_icon_object(icon_url, creator)
    image_id = Bonfire.Federate.ActivityPub.Utils.maybe_create_image_object(image_url, creator)

    {:ok, updated_actor} =
      case created_character do
        %Bonfire.Data.Identity.User{} ->
          Bonfire.Me.Users.ActivityPub.update(created_character, %{icon_id: icon_id, image_id: image_id})

        # %CommonsPub.Communities.Community{} ->
        #   CommonsPub.Communities.update(%Bonfire.Data.Identity.User{}, created_character, %{
        #     icon_id: icon_id,
        #     image_id: image_id
        #   })

        # %CommonsPub.Collections.Collection{} ->
        #   CommonsPub.Collections.update(%Bonfire.Data.Identity.User{}, created_character, %{
        #     icon_id: icon_id,
        #     image_id: image_id
        #   })
      end

    object = ActivityPub.Object.get_cached_by_ap_id(actor["id"])

    ActivityPub.Object.update(object, %{pointer_id: created_character.id})

    # Indexer.maybe_index_object(updated_actor) # this should be done in the context function being called

    {:ok, updated_actor}
  end

  def log(l) do
    if(Bonfire.Common.Config.get(:log_federation)) do
      Logger.warn(l)
    end
  end

  def error(error, attrs) do
    Logger.error("ActivityPub - Unable to process incoming federated activity - #{error}")

    IO.inspect(attrs: attrs)

    {:error, error}
  end
end
