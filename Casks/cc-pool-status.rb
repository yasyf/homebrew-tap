# cc-pool Notification Center widget (CCPoolStatus.app) cask. GENERATED per release
# by yasyf/homebrew-tap release-app.yml — edit .github/cask/cc-pool-status.rb.tmpl.
#
# Developer ID signed, notarized, and stapled, so Gatekeeper validates it offline;
# the postflight strips the download quarantine so first launch is silent. Install
# with `ccp widget`, or by hand: brew install --cask yasyf/tap/cc-pool-status
cask "cc-pool-status" do
  version "0.61.3"
  sha256 "ff654c0a8f6a99a7d55e2c0989e0d88787d665344fbaa2a535e0e6d8fe3ba075" # app

  url "https://github.com/yasyf/cc-pool/releases/download/v0.61.3/cc-pool-status-v0.61.3-darwin.zip"
  name "cc-pool Status"
  desc "cc-pool status, File Provider, and fixed FuseKit holder app"
  homepage "https://github.com/yasyf/cc-pool"

  depends_on macos: :sequoia # deployment target is macOS 15
  depends_on cask: "macos-fuse-t/homebrew-cask/fuse-t"
  depends_on formula: "cc-pool"

  app "CCPoolStatus.app", target: "/Applications/CCPoolStatus.app"

  preflight do
    # The exact daemonkit AppKeepAlive.Stop path must settle the signed holder
    # and unregister its service before Homebrew replaces the bundle.
    if Dir.exist?("/Applications/CCPoolStatus.app")
      system_command "#{HOMEBREW_PREFIX}/bin/ccp",
                     args: ["service", "holder-stop-uninstall"],
                     must_succeed: true
    end
  end

  postflight do
    # Strip Homebrew's download quarantine so first launch is silent (notarized+stapled).
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "/Applications/CCPoolStatus.app"],
                   must_succeed: false
    # Register and elect the exact File Provider before starting the daemon;
    # tenant provisioning must never race an absent extension registration.
    system_command "/usr/bin/pluginkit", args: ["-a", "/Applications/CCPoolStatus.app/Contents/PlugIns/CCPoolFileProvider.appex"], must_succeed: true
    system_command "/usr/bin/pluginkit", args: ["-e", "use", "-i", "com.yasyf.cc-pool.status.fileprovider"], must_succeed: true
    # The daemonkit-owned LaunchAgent is the sole holder lifecycle authority.
    system_command "#{HOMEBREW_PREFIX}/bin/ccp",
                   args: ["service", "install"],
                   must_succeed: true
  end

  uninstall_preflight do
    system_command "#{HOMEBREW_PREFIX}/bin/ccp",
                   args: ["service", "holder-stop-uninstall"],
                   must_succeed: true
  end

  zap trash: [
    "~/Library/Containers/com.yasyf.cc-pool.status.widget",
    "~/Library/Preferences/com.yasyf.cc-pool.status.plist",
  ]

  caveats <<~EOS
    The fixed app and daemon services are installed and started together.
    Add the widget from Notification Center → Edit Widgets → "cc-pool".

    File Provider domains are managed automatically by cc-pool. Health checks:
      ccp doctor
  EOS
end
