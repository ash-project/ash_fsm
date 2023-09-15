defmodule AshStateMachine do
  defmodule Transition do
    @moduledoc """
    The configuration for an transition.
    """
    @type t :: %__MODULE__{
            action: atom,
            from: [atom],
            to: [atom],
            __identifier__: any
          }

    defstruct [:action, :from, :to, :__identifier__]
  end

  require Logger

  @transition %Spark.Dsl.Entity{
    name: :transition,
    target: Transition,
    args: [:action],
    identifier: {:auto, :unique_integer},
    schema: [
      action: [
        type: :atom,
        doc:
          "The corresponding action that is invoked for the transition. Use `:*` to allow any update action to perform this transition."
      ],
      from: [
        type: {:or, [{:list, :atom}, :atom]},
        required: true,
        doc:
          "The states in which this action may be called. If not specified, then any state is accepted. Use `:*` to refer to all states."
      ],
      to: [
        type: {:or, [{:list, :atom}, :atom]},
        required: true,
        doc:
          "The states that this action may move to. If not specified, then any state is accepted. Use `:*` to refer to all states."
      ]
    ]
  }

  @transitions %Spark.Dsl.Section{
    name: :transitions,
    entities: [
      @transition
    ]
  }

  @state_machine %Spark.Dsl.Section{
    name: :state_machine,
    schema: [
      deprecated_states: [
        type: {:list, :atom},
        default: [],
        doc: """
        A list of states that have been deprecated.
        The list of states is derived from the transitions normally.
        Use this option to express that certain types should still
        be included in the derived state list even though no transitions
        go to/from that state anymore. `:*` transitions will not include
        these states.
        """
      ],
      extra_states: [
        type: {:list, :atom},
        default: [],
        doc: """
        A list of states that may be used by transitions to/from `:*`
        The list of states is derived from the transitions normally.
        Use this option to express that certain types should still
        be included even though no transitions go to/from that state anymore.
        `:*` transitions will include these states.
        """
      ],
      state_attribute: [
        type: :atom,
        doc: "The attribute to store the state in.",
        default: :state
      ],
      initial_states: [
        type: {:list, :atom},
        required: true,
        doc: "The allowed starting states of this state machine."
      ],
      default_initial_state: [
        type: :atom,
        doc: "The default initial state"
      ]
    ],
    sections: [
      @transitions
    ]
  }

  @sections [@state_machine]

  @moduledoc """
  Functions for working with AshStateMachine.
  <!--- ash-hq-hide-start --> <!--- -->

  ## DSL Documentation

  ### Index

  #{Spark.Dsl.Extension.doc_index(@sections)}

  ### Docs

  #{Spark.Dsl.Extension.doc(@sections)}
  <!--- ash-hq-hide-stop --> <!--- -->
  """

  use Spark.Dsl.Extension,
    sections: @sections,
    transformers: [
      AshStateMachine.Transformers.FillInTransitionDefaults,
      AshStateMachine.Transformers.AddState,
      AshStateMachine.Transformers.EnsureStateSelected
    ],
    verifiers: [
      AshStateMachine.Verifiers.VerifyTransitionActions,
      AshStateMachine.Verifiers.VerifyDefaultInitialState
    ],
    imports: [
      AshStateMachine.BuiltinChanges
    ]

  @doc """
  A utility to transition the state of a changeset, honoring the rules of the resource.
  """
  def transition_state(%{action_type: :update} = changeset, target) do
    transitions =
      AshStateMachine.Info.state_machine_transitions(changeset.resource, changeset.action.name)

    attribute = AshStateMachine.Info.state_machine_state_attribute!(changeset.resource)
    old_state = Map.get(changeset.data, attribute)

    if target in AshStateMachine.Info.state_machine_all_states(changeset.resource) do
      case Enum.find(transitions, fn transition ->
             old_state in List.wrap(transition.from) and target in List.wrap(transition.to)
           end) do
        nil ->
          Ash.Changeset.add_error(
            changeset,
            AshStateMachine.Errors.NoMatchingTransition.exception(
              old_state: old_state,
              target: target,
              action: changeset.action.name
            )
          )

        _transition ->
          Ash.Changeset.force_change_attribute(changeset, attribute, target)
      end
    else
      Logger.error("""
      Attempted to transition to an unknown state.

      This usually means that one of the following is true:

      * You have a missing transition definition in your state machine

        To remediate this, add a transition.

      * You are using `:*` to include a state that appears nowhere in the state machine definition

        To remediate this, add the `extra_states` option and include the state #{inspect(target)}
      """)

      Ash.Changeset.add_error(
        changeset,
        AshStateMachine.Errors.NoMatchingTransition.exception(
          old_state: old_state,
          target: target,
          action: changeset.action.name
        )
      )
    end
  end

  def transition_state(%{action_type: :create} = changeset, target) do
    attribute = AshStateMachine.Info.state_machine_state_attribute!(changeset.resource)

    if target in AshStateMachine.Info.state_machine_initial_states!(changeset.resource) do
      Ash.Changeset.force_change_attribute(changeset, attribute, target)
    else
      Ash.Changeset.add_error(
        changeset,
        AshStateMachine.Errors.InvalidInitialState.exception(
          target: target,
          action: changeset.action.name
        )
      )
    end
  end

  def transition_state(other, _target) do
    Ash.Changeset.add_error(other, "Can't transition states on destroy actions")
  end

  @doc """
  A reusable helper which returns all possible next states for a record
  (regardless of action).
  """
  @spec possible_next_states(Ash.Resource.record()) :: [atom]
  def possible_next_states(%resource{} = record) do
    state_attribute = AshStateMachine.Info.state_machine_state_attribute!(resource)
    current_state = Map.fetch!(record, state_attribute)

    resource
    |> AshStateMachine.Info.state_machine_transitions()
    |> Enum.map(&%{from: List.wrap(&1.from), to: List.wrap(&1.to)})
    |> Enum.filter(&(current_state in &1.from or :* in &1.from))
    |> Enum.flat_map(& &1.to)
    |> Enum.reject(&(&1 == :*))
    |> Enum.uniq()
  end

  @doc """
  A reusable helper which returns all possible next states for a record given a
  specific action.
  """
  @spec possible_next_states(Ash.Resource.record(), atom) :: [atom]
  def possible_next_states(%resource{} = record, action_name) when is_atom(action_name) do
    state_attribute = AshStateMachine.Info.state_machine_state_attribute!(resource)
    current_state = Map.fetch!(record, state_attribute)

    resource
    |> AshStateMachine.Info.state_machine_transitions(action_name)
    |> Enum.map(&%{from: List.wrap(&1.from), to: List.wrap(&1.to)})
    |> Enum.filter(&(current_state in &1.from or :* in &1.from))
    |> Enum.flat_map(& &1.to)
    |> Enum.reject(&(&1 == :*))
    |> Enum.uniq()
  end
end
