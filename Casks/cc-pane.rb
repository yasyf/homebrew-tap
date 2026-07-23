# Rendered by release-bun.yml from .github/formula/cc-pane.rb.tmpl — edit the template, not the tap copy.
cask "cc-pane" do
  version "0.1.1"

  on_macos do
    on_arm do
      sha256 "50d21195c50584c8ad9c3e53c1dca4d183cf2072a880f1724389d8f93ad0fb81"
      url "https://github.com/yasyf/cc-pane/releases/download/v#{version}/cc-pane-v#{version}-darwin-arm64.zip"
    end
    on_intel do
      sha256 "abf097bbaafe335737e196ebd42e373bd7e31b72d3e6723da5a088fc245c0afc"
      url "https://github.com/yasyf/cc-pane/releases/download/v#{version}/cc-pane-v#{version}-darwin-x64.zip"
    end
  end

  on_linux do
    on_arm do
      sha256 "fac9b50e392bd760aa0df31f673ee2da01e89d2cad86440af539abe88856c815"
      url "https://github.com/yasyf/cc-pane/releases/download/v#{version}/cc-pane-v#{version}-linux-arm64.zip"
    end
    on_intel do
      sha256 "69b3de9fae35105b2f315f1b7b8ada4bf9ca84fcd0e5d6e272775bc98f4c6354"
      url "https://github.com/yasyf/cc-pane/releases/download/v#{version}/cc-pane-v#{version}-linux-x64.zip"
    end
  end

  name "cc-pane"
  desc "Your whole Claude Code fleet in one pane of glass"
  homepage "https://github.com/yasyf/cc-pane"

  depends_on cask: "cc-orchestrate"
  depends_on formula: "cc-notes"

  binary "cc-pane"

  livecheck do
    skip "Auto-generated on release."
  end
end
