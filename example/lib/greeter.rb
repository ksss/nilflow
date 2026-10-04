class Greeter
  def initialize(store)
    @store = store
  end

  def name_for(id)
    @store.fetch(id)
  end

  def greet(id)
    n = name_for(id)
    "Hello " + n.upcase
  end

  def safe_greet(id)
    n = name_for(id)
    return "Hello stranger" unless n
    "Hello " + n.upcase
  end

  def nickname
    rand > 0.5 ? "nick" : nil
  end

  def shout
    nickname.upcase
  end
end
