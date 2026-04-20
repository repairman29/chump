class Chump < Formula
  desc "Multi-agent AI dispatcher with cognitive architecture"
  homepage "https://github.com/repairman29/chump"
  url "https://github.com/repairman29/chump/archive/refs/heads/main.tar.gz"
  version "0.1.0"
  license "MIT"

  depends_on "rust" => :build
  depends_on "sqlite"

  def install
    # Build the chump binary and install it under prefix
    system "cargo", "install",
           "--root", prefix,
           "--path", ".",
           "--bin", "chump"
  end

  test do
    system "#{bin}/chump", "--version"
  end
end
