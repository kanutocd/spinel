class HitState
  def initialize
    @material_index = nil
  end

  def hit!(idx)
    @material_index = idx
  end

  def label
    @material_index.nil? ? "miss" : "hit"
  end
end

state = HitState.new
puts state.label
state.hit!(0)
puts state.label
