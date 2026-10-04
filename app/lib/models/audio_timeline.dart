class AudioClip {
  const AudioClip(this.path, this.duration);
  final String path;
  final Duration duration;
}

class AudioTimeline {
  AudioTimeline(List<AudioClip> clips) : clips = List.unmodifiable(clips);
  final List<AudioClip> clips;
  Duration get duration =>
      clips.fold(Duration.zero, (sum, c) => sum + c.duration);
  Duration position(int index, Duration within) =>
      clips.take(index).fold(Duration.zero, (sum, c) => sum + c.duration) +
      within;
  ({int index, Duration position}) locate(Duration position) {
    var remaining = position.inMilliseconds.clamp(0, duration.inMilliseconds);
    for (var i = 0; i < clips.length; i++) {
      final length = clips[i].duration.inMilliseconds;
      if (remaining < length || i == clips.length - 1) {
        return (
          index: i,
          position: Duration(milliseconds: remaining.clamp(0, length)),
        );
      }
      remaining -= length;
    }
    return (index: 0, position: Duration.zero);
  }
}
