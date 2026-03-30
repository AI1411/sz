class Sz < Formula
  desc "Fast directory size visualizer with TUI mode"
  homepage "https://github.com/AI1411/sz"
  version "0.1.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/AI1411/sz/releases/download/v#{version}/sz-macos-arm64.tar.gz"
      sha256 "8e3222523c524b00130e1c4c0265248f33e54f88d5114fcc69502193b60a1cd2"
    end
    on_intel do
      url "https://github.com/AI1411/sz/releases/download/v#{version}/sz-macos-x86_64.tar.gz"
      sha256 "ff1b1d592d3da4e9ff6037dd458a59fd044585d8394f2d6aec7385e1cfe88670"
    end
  end

  def install
    bin.install "sz"
  end

  test do
    assert_match "sz #{version}", shell_output("#{bin}/sz --version")
  end
end
