# The allowlist for the HTML part of a forward copy. A forward copy reaches the owner from the owner's
# own DKIM-signed domain, so whatever survives here borrows that trust. Formatting and links stay;
# anything that runs, submits, embeds or loads from elsewhere goes. Images become a short note, naming
# the host when the image was remote (those are trackers). CSS in style attributes goes through Loofah's
# CSS allowlist, with stricter spacing and layout rules so the original cannot cover the banner.
class ForwardHtmlScrubber < Rails::HTML::PermitScrubber
  TAGS = %w[a abbr b bdi bdo big blockquote br caption center cite code col colgroup dd del dfn div dl dt em
    font h1 h2 h3 h4 h5 h6 hr i ins kbd li mark ol p pre q s samp small span strike strong sub sup
    table tbody td tfoot th thead time tr tt u ul var].freeze
  ATTRIBUTES = %w[align alt bgcolor border cellpadding cellspacing color colspan dir face height href lang
    rowspan size span start style title valign width].freeze
  # Removed together with their content. Any other tag outside TAGS (form, label, section...) is
  # unwrapped: the tag goes, its text stays.
  DROPPED = %w[script style link meta base title iframe frame frameset object embed applet noscript template
    input button select textarea option optgroup datalist audio video source track canvas].freeze
  FORBIDDEN_LAYOUT = %w[position top left right bottom z-index transform float].freeze
  SPACING_VALUE = /\A(?:auto|0|(?:\d+(?:\.\d+)?|\.\d+)(?:px|em|rem|ex|ch|cap|ic|lh|rlh|vw|vh|vmin|vmax|cm|mm|q|in|pt|pc|%))\z/i

  def initialize
    super
    self.tags = TAGS
    self.attributes = ATTRIBUTES
  end

  def scrub(node)
    if node.element? && DROPPED.include?(node.name)
      node.remove
      return STOP
    end
    if node.element? && node.name == "img"
      node.replace(Nokogiri::XML::Text.new(image_note(node["src"]), node.document))
      return STOP
    end
    super
  end

  protected

  def scrub_css_attribute(node)
    # Filter before Loofah can discard individual tokens and turn an unsafe declaration into one
    # that appears safe. Crass decodes escaped property names and respects CSS declaration boundaries.
    if (style = node["style"])
      kept = Crass.parse_properties(style).select { |property| safe_layout?(property) }
      node["style"] = kept.map { |property| Crass::Parser.stringify(property) }.join(";")
    end
    super
    node.remove_attribute("style") if node["style"].blank?
  end

  private

  def safe_layout?(property)
    return false unless property[:node] == :property
    name = property[:name].downcase
    value = property[:value].to_s.strip
    return false if FORBIDDEN_LAYOUT.include?(name) || name.start_with?("clip")
    return %w[block inline none].include?(value.downcase) if name == "display"
    if name.start_with?("margin", "padding")
      values = value.split
      return values.length.between?(1, 4) && values.all? { |part| part.match?(SPACING_VALUE) }
    end
    true
  end

  def image_note(src)
    host = URI.parse(src.to_s.strip.tr("\\", "/")).host
    host.present? ? "[remote image removed: #{host.downcase.truncate(100)}]" : "[image removed]"
  rescue URI::InvalidURIError
    "[image removed]"
  end
end
