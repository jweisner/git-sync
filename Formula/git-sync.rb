class GitSync < Formula
  desc "Scan a directory tree for git repos and keep them in sync"
  homepage "https://github.com/jweisner/git-sync"
  url "https://github.com/jweisner/git-sync/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "3b3dd384f20314bb323a8945feb9f717553c87e2b9274a5be1cd7b3bce020790"
  license "Apache-2.0"

  def install
    bin.install "git-sync"
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/git-sync --help")
  end
end
