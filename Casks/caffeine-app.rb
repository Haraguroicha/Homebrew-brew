cask "caffeine-app" do
  name "Caffeine"
  desc "Keeps your Mac awake. Caffeine is a tiny open source program that puts an icon in the right side of your menubar. Click it to prevent your Mac from automatically going to sleep, dimming the screen or starting screen savers."

  on_monterey do
    version "1.2.1"
    sha256 "a256120d17983c89de3bdacd97f3e84e488c9782e6b2365ced365593a29beee5"
  end
  on_ventura do
    version "1.3.0"
    sha256 "201f3de57b11e1faec3307f00fb81ecab8ed2c433e94010de88b1edc4edbd15f"
  end
  on_sonoma do
    version "1.4.3"
    sha256 "5d1127fe3a5be772c61b9685915bd244b2e47b4607242b0d3b9cc517f5269c43"
  end
  on_sequoia do
    version "1.5.3"
    sha256 "91dcb16138f97d21a19e9dc62f41a7d4b1329728d7027da50ae61fca0db1d066"
  end
  on_tahoe do
    version "1.6.3"
    sha256 "0d9ff8bf1fdcf1b3a0b22cdc18e311d4d25c99a0adb411098c9f1597c11f6e15"
  end

  homepage "https://www.caffeine-app.net/?macos=#{MacOS.full_version.pretty_name.downcase}"
  url "https://www.caffeine-app.net/download/#{MacOS.full_version.pretty_name.downcase}"

  app "Caffeine.app"
end
