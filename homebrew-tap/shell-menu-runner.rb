class ShellMenuRunner < Formula
  desc "Zero-dependency task runner"
  homepage "https://github.com/MarioPeters/shell-menu-runner/"
  url "https://github.com/MarioPeters/shell-menu-runner/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "5949c755d19a767a9c26963f88ce21d7e1495e1ca3d1524bf998991d5a6151a6"
  license "MIT"
  def install
    bin.install "run.sh" => "run"
  end
end
