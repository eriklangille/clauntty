defmodule Review.Notes do
  @moduledoc "A review's notes, as Claude writes them"

  @priorities ~w(critical review skim mechanical)a

  defstruct path: nil, priority: :skim

  @spec rank(%__MODULE__{}) :: non_neg_integer()
  def rank(%__MODULE__{priority: p}) do
    Enum.find_index(@priorities, &(&1 == p)) || 2
  end

  def label(%{path: path} = note), do: "#{path} (#{rank(note)})\n"
end
