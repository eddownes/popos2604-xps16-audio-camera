// >>> popos2604-xps16-audio-camera >>>
// Use the PipeWire camera portal, so Firefox sees the libcamera camera.
user_pref("media.webrtc.camera.allow-pipewire", true);
// Pages that don't ask for a size get 1920x1080 (full field of view).
user_pref("media.navigator.video.default_width", 1920);
user_pref("media.navigator.video.default_height", 1080);
user_pref("media.navigator.video.default_fps", 30);
// <<< popos2604-xps16-audio-camera <<<
