require "test_helper"

class ForwardHtmlScrubberTest < ActiveSupport::TestCase
  def sanitize(style)
    Rails::HTML5::SafeListSanitizer.new.sanitize(%(<p style="#{style};color:red">Original</p>), scrubber: ForwardHtmlScrubber.new)
  end

  [ "margin-top:calc(0px - (300px))", "margin-top:calc(1px - +300px)",
    "margin:calc(0px - (300px)) 0 0 0", "margin-top:calc(0px - var(--x, 300px))",
    "margin:var(--x)", "padding:var(--x)", "margin:-300px", "padding:-1px",
    "margin:min(1px, 2px)", "margin:max(1px, 2px)", "padding:clamp(0px, 1px, 2px)",
    "margin:inherit", "margin:1px garbage", "position:absolute", "top:0", "left:0", "right:0", "bottom:0",
    "z-index:999", "transform:translateY(-300px)", "float:left", "clip:rect(0,0,0,0)",
    "clip-path:inset(0)", "display:inline-block", "display:table" ].each do |style|
    test "drops unsafe declaration #{style}" do
      assert_equal '<p style="color:red;">Original</p>', sanitize(style)
    end
  end

  test "preserves plain nonnegative spacing and simple display" do
    [ "margin:0 auto 1px 10%", "padding:0 2em .5rem 10%", "display:block", "display:inline", "display:none" ].each do |style|
      assert_includes sanitize(style), style
    end
  end
end
