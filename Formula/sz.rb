class Sz < Formula
  desc "Fast directory size visualizer with TUI mode"
  homepage "https://github.com/AI1411/sz"
  version "0.1.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/AI1411/sz/releases/download/v#{version}/sz-macos-arm64.tar.gz"
      sha256 "REPLACE_WITH_ARM64_SHA256"
    end
    on_intel do
      url "https://github.com/AI1411/sz/releases/download/v#{version}/sz-macos-x86_64.tar.gz"
      sha256 "REPLACE_WITH_X86_64_SHA256"
    end
  end

  def install
    bin.install "sz"
  end

  test do
    assert_match "sz #{version}", shell_output("#{bin}/sz --version")
  end
end
