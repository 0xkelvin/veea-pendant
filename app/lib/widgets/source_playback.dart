import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../models/audio_timeline.dart';

/// Playback stays attached to the reviewed recording; seeking never edits it.
class SourcePlayback extends StatefulWidget {
  const SourcePlayback({
    super.key,
    required this.player,
    required this.path,
    required this.duration,
    required this.enabled,
    required this.onError,
    this.clips,
  });

  final AudioPlayer player;
  final String path;
  final List<AudioClip>? clips;
  final Duration duration;
  final bool enabled;
  final ValueChanged<String> onError;

  @override
  State<SourcePlayback> createState() => _SourcePlaybackState();
}

class _SourcePlaybackState extends State<SourcePlayback> {
  bool _loaded = false, _loading = false;
  double? _dragMs;
  AudioTimeline? _timeline;
  List<AudioClip> get _availableClips =>
      widget.clips ?? [AudioClip(widget.path, widget.duration)];
  bool get _hasNewAudio =>
      _loaded &&
      _timeline != null &&
      _timeline!.clips.map((c) => c.path).join('|') !=
          _availableClips.map((c) => c.path).join('|');
  Duration get _position => _loaded && _timeline != null
      ? _timeline!.position(
          widget.player.currentIndex ?? 0,
          widget.player.position,
        )
      : Duration.zero;

  @override
  void didUpdateWidget(SourcePlayback oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before =
        (oldWidget.clips ?? [AudioClip(oldWidget.path, oldWidget.duration)])
            .map((c) => c.path)
            .toList();
    final after = _availableClips.map((c) => c.path).toList();
    final prefix =
        after.length >= before.length &&
        List.generate(
          before.length,
          (i) => after[i] == before[i],
        ).every((v) => v);
    final changed = oldWidget.path != widget.path || !prefix;
    if (changed) {
      _loaded = false;
      _timeline = null;
      _dragMs = null;
    }
    if (changed || (oldWidget.enabled && !widget.enabled)) {
      unawaited(
        widget.player.pause().catchError((Object e) => widget.onError('$e')),
      );
    }
  }

  @override
  void dispose() {
    unawaited(widget.player.pause().catchError((Object _) {}));
    super.dispose();
  }

  String _time(Duration duration) {
    final seconds = duration.inSeconds;
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _act({Duration? seekTo, bool toggle = false}) async {
    if (_loading || !widget.enabled) return;
    final path = widget.path;
    setState(() => _loading = true);
    try {
      final player = widget.player;
      if (!_loaded) {
        await player.pause();
        final clips = List<AudioClip>.of(_availableClips);
        if (clips.isEmpty) return;
        await player.setAudioSources(
          clips.map((c) => AudioSource.file(c.path)).toList(),
        );
        if (!mounted || path != widget.path) return;
        _timeline = AudioTimeline(
          clips.length == 1 && player.duration != null
              ? [AudioClip(clips.first.path, player.duration!)]
              : clips,
        );
        if (!mounted || path != widget.path) return;
        _loaded = true;
      }
      if (!widget.enabled) return;
      if (seekTo != null) {
        final target = _timeline!.locate(seekTo);
        await player.seek(target.position, index: target.index);
      }
      if (!mounted || path != widget.path || !widget.enabled) return;
      if (toggle) {
        if (player.playing &&
            player.processingState != ProcessingState.completed) {
          await player.pause();
        } else {
          if (player.processingState == ProcessingState.completed) {
            await player.seek(Duration.zero, index: 0);
          }
          if (!mounted || path != widget.path || !widget.enabled) return;
          // play() completes at the end of playback, so don't await it here.
          unawaited(
            player.play().catchError((Object e) {
              if (mounted) widget.onError('$e');
            }),
          );
        }
      }
    } catch (e) {
      if (mounted) widget.onError('$e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _dragMs = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<PlayerState>(
    stream: widget.player.playerStateStream,
    builder: (context, _) => StreamBuilder<Duration?>(
      stream: widget.player.durationStream,
      builder: (context, _) => StreamBuilder<Duration>(
        stream: widget.player.positionStream,
        builder: (context, _) {
          final player = widget.player;
          final duration = _loaded
              ? _timeline?.duration ?? widget.duration
              : AudioTimeline(_availableClips).duration;
          final maxMs = duration.inMilliseconds.clamp(0, 1 << 53).toDouble();
          final position = _position;
          final value = (_dragMs ?? position.inMilliseconds.toDouble()).clamp(
            0.0,
            maxMs,
          );
          final enabled = widget.enabled && !_loading;
          final playing =
              _loaded &&
              player.playing &&
              player.processingState != ProcessingState.completed;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.clips == null ? 'Source audio' : 'Conversation audio',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (widget.clips != null)
                const Text(
                  'Plays saved sections in order. Gaps between recordings are skipped.',
                  style: TextStyle(fontSize: 12),
                ),
              if (_hasNewAudio)
                TextButton(
                  onPressed: _loading
                      ? null
                      : () async {
                          await widget.player.pause();
                          if (mounted) {
                            setState(() {
                              _loaded = false;
                              _timeline = null;
                            });
                          }
                        },
                  child: const Text('Load newer audio'),
                ),
              Slider(
                value: value,
                max: maxMs > 0 ? maxMs : 1,
                semanticFormatterCallback: (v) =>
                    _time(Duration(milliseconds: v.round())),
                onChanged: enabled && maxMs > 0
                    ? (v) => setState(() => _dragMs = v)
                    : null,
                onChangeEnd: enabled && maxMs > 0
                    ? (v) => _act(seekTo: Duration(milliseconds: v.round()))
                    : null,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_time(Duration(milliseconds: value.round()))),
                  Text(_time(duration)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Back 10 seconds',
                    onPressed: enabled && maxMs > 0
                        ? () => _act(
                            seekTo: position - const Duration(seconds: 10),
                          )
                        : null,
                    icon: const Icon(Icons.replay_10),
                  ),
                  FilledButton.icon(
                    onPressed: enabled ? () => _act(toggle: true) : null,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    label: Text(
                      _loading
                          ? 'Loading…'
                          : playing
                          ? 'Pause'
                          : 'Play source',
                    ),
                  ),
                  IconButton(
                    tooltip: 'Forward 10 seconds',
                    onPressed: enabled && maxMs > 0
                        ? () => _act(
                            seekTo: position + const Duration(seconds: 10),
                          )
                        : null,
                    icon: const Icon(Icons.forward_10),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    ),
  );
}
