# Stable RTSP stream URL from MIPC

##In this repository I show how I fixed the issue with expiring RTSP URLs from MIPC cameras.

I have a cheap Chinese camera that works with the MIPC app. The only way to get a live stream out of it locally is an `rtmp://<camera-ip>:7010/live/<token>` URL, and that token doesn't last. A URL that works once stops working a few minutes later, or as soon as the session that used it is closed. Pasting it into Scrypted, VLC or an NVR gives you a picture for a moment and then nothing.

This repo is how I got a stable RTSP address out of it. A small shell script asks the camera for a fresh URL every few minutes and pushes it into go2rtc. Everything else (Home Assistant, Scrypted, VLC) just uses the go2rtc address, `rtsp://<HA_IP>:8554/mipc_camera`, which never changes.

It took me a lot of trial and error, and I only really understood why it worked afterwards, so I wrote down what I learned. I've tested it on one camera only. It has been running without problems for weeks, but I can't promise it works on other models or firmware.

## What you need

- Home Assistant with add-ons
- the go2rtc add-on (its API on port 1984 and RTSP on 8554)
- the Terminal & SSH add-on, which runs the script in the background
- the camera on your LAN and its admin password
- the Python package `mipc-camera-client`, installed through pip (see step 3). It's a third-party package and it gets your camera password, so read its source before trusting it.

## Setup

1. Install and start the go2rtc add-on and make sure ports 1984 and 8554/tcp are exposed in its network settings. You don't need to define the camera in `go2rtc.yaml`, the script creates the stream through the API.

2. Copy `scripts/refresh_mipc.sh` and `scripts/refresh_mipc.env.example` to `/homeassistant/scripts/`. Rename the example to `refresh_mipc.env`, fill it in and make the script executable with `chmod +x`. Inside the Terminal & SSH add-on your Home Assistant config is at `/homeassistant`, not `/config` (that one is the add-on's own folder). I lost a while to this: the script silently never started because of the wrong path.

   The env file takes `CAMERA_IP`, `CAMERA_PASSWORD` and optionally `CAMERA_USER` (default `admin`), `GO2RTC_URL` (default `http://localhost:1984`), `STREAM_NAME` (default `mipc_camera`) and `REFRESH_INTERVAL` (default 270 seconds). If you also set `HA_URL` and `HA_TOKEN`, the script writes the current URL into an `input_text` entity, which is handy for debugging but not required.

   The file contains secrets. It is in `.gitignore`, so keep it out of the repo.

3. In the Terminal & SSH add-on configuration add:

   ```yaml
   packages:
     - python3
     - py3-pip
   init_commands:
     - pip install --break-system-packages --no-cache-dir mipc-camera-client
     - nohup /homeassistant/scripts/refresh_mipc.sh >> /homeassistant/scripts/refresh_mipc.log 2>&1 &
   ```

   Turn on "Start on boot" for that add-on too, otherwise the stream is gone after every reboot. Save and restart the add-on.

4. Check that it runs:

   ```bash
   tail -n 5 /homeassistant/scripts/refresh_mipc.log
   ps aux | grep refresh_mipc | grep -v grep
   ```

   The log should have "stream URL refreshed" lines and there should be exactly one process. Then open the go2rtc add-on's web UI (Settings → Add-ons → go2rtc → Open Web UI). The stream `mipc_camera` should be listed, and `stream.html` should show video. Test the RTSP address from another machine:

   ```bash
   ffplay -rtsp_transport tcp "rtsp://<HA_IP>:8554/mipc_camera"
   ```

From here the stream works anywhere that speaks RTSP. In Home Assistant I use it through go2rtc, but a Generic Camera with that RTSP URL should do as well.

## Scrypted

In Scrypted I use the FFmpeg Camera plugin and put this in "FFmpeg Input Stream Arguments":

```
-rtsp_transport tcp -i rtsp://<HA_IP>:8554/mipc_camera
```

The `-i` matters, that field goes straight into the ffmpeg command line, and without it you get no picture and no error. TCP is there because UDP between containers lost packets for me. You don't need to touch the Rebroadcast settings, those `localhost:45083` URLs are what Scrypted outputs, not where it reads from.

## How it works and what went wrong along the way

`mipc_camera_client stream` logs in to the camera and prints a fresh tokenized `rtmp://` URL. The script hands that to go2rtc as `ffmpeg:<url>#video=copy#audio=copy` and repeats every ~4.5 minutes.

For a long time this half worked. Opening the stream once was fine, but closing the page and opening it again gave `Error opening input: I/O error` until the next refresh. As far as I can tell, go2rtc only connects to the camera when someone starts watching, and by then it reuses a URL the camera already won't accept again. The fix was a call to go2rtc's preload API, so it keeps one connection to the camera open all the time and every viewer attaches to that. If the preload call returns 404, your go2rtc is too old and needs an update.

Two side effects. Every refresh replaces the source, so you may see a tiny hiccup every few minutes. And streams created through the API aren't saved, so after a go2rtc restart the stream is missing until the script's next round.

Things that tripped me up, in case they trip you too:

- `nohup: can't execute '/config/scripts/...'` in the log means the wrong path, use `/homeassistant/...`.
- If the log grows twice as fast as expected, two copies of the script are running. Find them with `ps aux | grep refresh_mipc` and kill the extra one.
- I had a REST sensor in `configuration.yaml` that logged in to the camera every 30 minutes. It was a leftover from an earlier attempt and it may well have interfered with the session, so I removed it. If the camera keeps dropping sessions, check that nothing else is logging in to it.
- The old log lines stay in the file because the script appends to it, so errors from the first start can sit at the top of the log for a long time. Check the end of the file.

## Security

Keep the env file, Home Assistant tokens and the camera password out of git. Use a separate long-lived token for this script so you can revoke it on its own. Don't expose go2rtc's ports to the internet, it has no authentication by default. The stream URL contains a token and ends up in the log and in the optional `input_text` entity.
