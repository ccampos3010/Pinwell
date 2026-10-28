# Pinwell for iPhone

Native app. It is not a web page. ARKit reads the LiDAR depth buffer in meters and presses the pins when something is inside 25 cm. Laying the screen flat toward the sky slides them back over about 3 seconds. Tilt up and they stop where they are.

Needs an iPhone 12 Pro, 13 Pro, 14 Pro, 15 Pro, 16 Pro, or any newer Pro. Phones without LiDAR open the app and say so.

## Free install from Windows

No Apple Developer fee. The app stops opening after 7 days until you sign it again with the same Apple ID. Sideloadly can do that refresh from the PC. You can have 3 sideloaded apps at a time.

1. Put this project in a **public** GitHub repository. Public is what makes the Mac build free. Do not add secrets to that repo.
2. On GitHub, open Actions, run **Unsigned iOS IPA**, and download `Pinwell-unsigned.ipa` when it finishes.
3. On the Windows PC, install Apple’s iTunes and iCloud from Apple’s site, not the Microsoft Store copies. Then install [Sideloadly](https://sideloadly.io/).
4. On the iPhone, turn on Settings → Privacy & Security → Developer Mode, then restart.
5. Plug the phone in, open Sideloadly, sign in with a free Apple ID, and drop in the IPA. Use a spare Apple ID if you do not want this on your main one.
6. On the phone, trust the certificate if iOS asks: Settings → General → VPN & Device Management. Allow Camera and Motion when Pinwell asks.

Hold an object within 25 cm of the back of the phone. The pins stay up until you lay the screen flat, facing the sky, or tap Reset.

## Install from a Mac you own

A free Apple ID is enough. The signature lasts 7 days, then press Run again.

1. Unzip on a Mac with Xcode 16 or newer.
2. Open `Pinwell.xcodeproj`.
3. Plug in the iPhone and trust the computer.
4. On the iPhone: Settings → Privacy & Security → Developer Mode → on, then restart.
5. In Xcode, select the Pinwell target → Signing & Capabilities → Team → your Apple ID (Personal Team). If the bundle id is taken, change `app.pinwell.lidar` to something of your own.
6. Choose your iPhone as the run destination, not a simulator. The simulator has no LiDAR.
7. Press Run. On the phone, tap Trust for the developer certificate if iOS asks (Settings → General → VPN & Device Management).
8. Allow Camera and Motion when Pinwell asks.
