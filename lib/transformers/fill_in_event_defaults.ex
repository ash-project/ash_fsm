defmodule AshStateMachine.Transformers.FillInTransitionDefaults do
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer
  @moduledoc false

  def transform(dsl_state) do
    initial_states = AshStateMachine.Info.state_machine_initial_states!(dsl_state)

    transitions =
      dsl_state
      |> AshStateMachine.Info.state_machine_transitions()

    all_states =
      transitions
      |> Enum.flat_map(fn transition ->
        List.wrap(transition.from) ++ List.wrap(transition.to)
      end)
      |> Enum.concat(List.wrap(initial_states))
      |> Enum.uniq()
      |> Enum.reject(&(&1 == :*))

    dsl_state =
      Transformer.set_option(
        dsl_state,
        [:state_machine],
        :initial_states,
        List.wrap(initial_states)
      )

    {:ok,
     transitions
     |> Enum.reduce(dsl_state, fn transition, dsl_state ->
       Transformer.replace_entity(dsl_state, [:ash_state_machine, :transitions], %{
         transition
         | from: replace_star(transition.from, all_states),
           to: replace_star(transition.to, all_states)
       })
     end)
     |> Transformer.persist(:all_state_machine_states, all_states)}
  end

  defp replace_star(states, all_states) do
    states
    |> List.wrap()
    |> Enum.flat_map(fn
      :* ->
        all_states

      other ->
        List.wrap(other)
    end)
  end
end
