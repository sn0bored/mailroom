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

  test "decoy closing delimiters do not hide nesting" do
    source = nested(1000).gsub(/^(--b\d+)$/, "\\1--x\n\\1")
    assert_equal 33, depth(source)
  end

  test "RFC 2231 boundary parameters count toward nesting" do
    [ 'boundary*0="', 'boundary*="', 'boundary*="us-ascii\'\'' ].each do |parameter|
      assert_equal 33, depth(nested(1000).gsub('boundary="', parameter)), parameter
    end
  end

  test "indented boundary parameters in body text do not count" do
    assert_equal 0, depth("Content-Type: text/plain\n\n" + (" boundary=body\n" * 33))
  end

  test "headers quoted inside a DSN digest are body text" do
    source = +"Content-Type: multipart/digest; boundary=digest\n\n"
    40.times do |i|
      source << "--digest\nContent-Type: text/rfc822-headers\n\nContent-Type: multipart/mixed; boundary=b#{i}\n\n"
    end
    source << "--digest--\n"
    assert_equal 1, depth(source)
  end

  test "split encoded and quoted boundary parameters use Mail decoding" do
    [
      "boundary*0*=us-ascii''%62;\n\tboundary*1=0",
      'boundary="b0"',
      "boundary*=us-ascii''%620"
    ].each do |parameter|
      source = nested(2).sub('boundary="b0"', parameter)
      assert_equal 2, depth(source), parameter
      assert_equal "b0", Mail.new(source).boundary
    end
  end

  test "only Content-Type continuation lines declare boundaries" do
    source = "Content-Type: text/plain\nSubject: boundary=subject\n\tboundary=continued\n" \
      "Content-Disposition: attachment; boundary=disposition\n\nbody"
    assert_equal 0, depth(source)
  end

  test "closing delimiters accept only horizontal trailing whitespace" do
    source = nested(2).sub("--b1--\n", "--b1-- \t\r\n")
    source = source.sub("--b0--\n", "--b0\nContent-Type: multipart/mixed; boundary=other\n\n--other\n\nbody\n--other--\n--b0--\n")
    assert_equal 2, depth(source)
  end
end
