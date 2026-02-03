class ShellMenuRunner < Formula
  desc "Zero-dependency task runner"
  homepage "https://github.com/MarioPeters/shell-menu-runner/"
  url "https://github.com/MarioPeters/shell-menu-runner/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "REPLACE_THIS"
  license "MIT"
  def install
    bin.install "run.sh" => "run"
  end
end
