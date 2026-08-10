---
"devctl": patch
---

Installing from the DMG no longer leaves a disk that will not eject. The daemon could end up running its program straight from the mounted disk image instead of the copy in Applications, because the image and the installed app share an identity and macOS sometimes preferred the mounted one. While that lasted, the disk reported itself in use and refused to eject until the daemon happened to restart. The daemon now notices at startup when it is running from a mounted volume and relaunches itself from the installed copy first, so the image is free to eject right after you drag the app to Applications.
