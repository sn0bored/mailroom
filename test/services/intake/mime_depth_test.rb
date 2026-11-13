require "test_helper"

class Intake::MimeDepthTest < ActiveSupport::TestCase
  def nested(depth, leaf: "Content-Type: text/plain\n\nleaf\n")
    body = +""
    depth.times { |i| body << "Content-Type: multipart/mixed; boundary=\"b#{i}\"\n\n--b#{i}\n" }
    body << leaf
    (depth - 1).downto(0) { |i| body << "--b#{i}--\n" }
    "From: a@sender.example.net\nTo: hello@example.org\nSubject: nest\nMIME-Version: 1.0\n" + body
  end

  def depth(source, limit: 32) = Intake::MimeDepth.call(source, limit: limit)

  test "counts nesting, not boundaries" do
    assert_equal 0, depth(forwarded_source)
    assert_equal 3, depth(nested(3))

    siblings = +"Content-Type: multipart/mixed; boundary=\"outer\"\n\n"
    40.times do |i|
      siblings << "--outer\nContent-Type: multipart/alternative;\n\tboundary=inner#{i}\n\n--inner#{i}\nContent-Type: text/plain\n\nx\n--inner#{i}--\n"
    end
    siblings << "--outer--\n"
    assert_equal 2, depth(siblings)
  end

  test "a missing inner close is closed by its parent's" do
    source = "Content-Type: multipart/mixed; boundary=a\n\n--a\nContent-Type: multipart/mixed; boundary=b\n\n--b\nx\n--a--\n" \
             "Content-Type: multipart/mixed; boundary=c\n\n--c\nx\n--c--\n"
    assert_equal 2, depth(source)
  end

  test "boundary= in body text is not a boundary" do
    text = "Content-Type: text/plain\n\n" + ("the boundary=\"x\" parameter\n" * 50)
    assert_equal 0, depth(text)
  end

  test "stops counting past the limit" do
    assert_equal 33, depth(nested(5000))
  end
end
