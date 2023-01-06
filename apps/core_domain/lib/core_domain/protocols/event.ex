defprotocol CoreDomain.Protocols.Event do
  @moduledoc """
  Protocol for domain events.

  All events in the system must implement this protocol to provide:
  - Event type identification
  - Timestamp information
  - Serialization support
  """

  @doc """
  Returns the event type as an atom.
  """
  @spec event_type(t()) :: atom()
  def event_type(event)

  @doc """
  Returns the timestamp when the event occurred.
  """
  @spec timestamp(t()) :: DateTime.t()
  def timestamp(event)

  @doc """
  Returns metadata associated with the event.
  """
  @spec metadata(t()) :: map()
  def metadata(event)
end
