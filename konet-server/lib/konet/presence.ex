defmodule Konet.Presence do
  use Phoenix.Presence,
    otp_app: :konet,
    pubsub_server: Konet.PubSub
end
