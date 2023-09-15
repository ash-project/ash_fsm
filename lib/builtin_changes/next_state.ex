defmodule AshStateMachine.BuiltinChanges.NextState do
  @moduledoc """
  Given the action and the current state, attempt to find the next state to
  transition into.
  """
  use Ash.Resource.Change

  def change(changeset, _opts, _) do
    changeset.data
    |> AshStateMachine.possible_next_states(changeset.action.name)
    |> case do
      [to] ->
        AshStateMachine.transition_state(changeset, to)

      [] ->
        Ash.Changeset.add_error(changeset, "Cannot determine next state: no next state available")

      _ ->
        Ash.Changeset.add_error(
          changeset,
          "Cannot determine next state: multiple next states available"
        )
    end
  end
end
