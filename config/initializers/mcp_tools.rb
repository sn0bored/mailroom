Rails.application.config.to_prepare do
  registry = Mcp::ToolRegistry.instance
  registry.reset!
  [
    Mcp::Tools::ListDomains,
    Mcp::Tools::ListMessages,
    Mcp::Tools::GetMessage,
    Mcp::Tools::GetAttachment,
    Mcp::Tools::UpdateMessage,
    Mcp::Tools::DraftReply
  ].each { |tool| registry.register(tool) }
end
