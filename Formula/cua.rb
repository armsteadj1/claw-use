class Cua < Formula
  desc "Allowing claws to make better use of any application"
  homepage "https://github.com/thegreysky/agentview"
  url "https://github.com/thegreysky/agentview/releases/latest/download/cua-macos-universal.tar.gz"
  version "0.3.0"
  license "MIT"

  depends_on :macos

  def install
    bin.install "cua"
    bin.install "cuad"
  end

  def caveats
    <<~EOS
      Grant Accessibility permission to cua when prompted.
      For Safari: enable Develop → Allow JavaScript from Apple Events.

      Start the daemon:
        cua daemon start
    EOS
  end

  test do
    assert_match "USAGE", shell_output("#{bin}/cua --help", 0)
  end
end
