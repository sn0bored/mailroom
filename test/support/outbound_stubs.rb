# Small scoped replacement helper, without an additional mocking dependency.
module OutboundStubs
  refine Object do
    def stub(name, replacement)
      original = method(name)
      owned = singleton_class.instance_methods(false).include?(name)
      singleton_class.define_method(name) do |*args, **kwargs, &block|
        replacement.respond_to?(:call) ? replacement.call(*args, **kwargs, &block) : replacement
      end
      yield
    ensure
      if owned
        singleton_class.define_method(name, original)
      else
        singleton_class.remove_method(name)
      end
    end
  end
end
