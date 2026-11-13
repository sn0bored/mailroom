# The allowlist for the HTML part of a forward copy. A forward copy reaches the owner from the owner's
# own DKIM-signed domain, so whatever survives here borrows that trust. Formatting and links stay;
# anything that runs, submits, embeds or loads from elsewhere goes. Images become a short note, naming
# the host when the image was remote (those are trackers). CSS in style attributes goes through Loofah's
# CSS allowlist, which drops url() and unknown properties; negative margins go too, so the original
# cannot slide up over the provenance banner.
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
  NEGATIVE_MARGIN = /\Amargin[\w-]*\s*:.*(?<![\w.])-\s*\.?\d/i

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
    super
    return unless (style = node["style"])
    kept = style.split(";").map(&:strip).reject { |declaration| declaration.empty? || declaration.match?(NEGATIVE_MARGIN) }
    kept.empty? ? node.remove_attribute("style") : node["style"] = "#{kept.join(';')};"
  end

  private

  def image_note(src)
    host = URI.parse(src.to_s.strip.tr("\\", "/")).host
    host.present? ? "[remote image removed: #{host.downcase.truncate(100)}]" : "[image removed]"
  rescue URI::InvalidURIError
    "[image removed]"
  end
end
