module Mcp
  class ToolRegistry
    include Singleton

    def reset! = @tools = {}
    def register(klass) = tools[klass.tool_name] = klass
    def lookup(name) = tools[name.to_s]
    def manifests_for(api_key) = tools.values.select { |t| t.allowed?(api_key) }.map(&:manifest)
    def names = tools.keys

    private

    def tools = (@tools ||= {})
  end
end
