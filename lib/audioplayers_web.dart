import 'dart:async';
import 'dart:html';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

class WrappedPlayer {
  final String playerId;
  double pausedAt;
  double currentVolume = 1.0;
  ReleaseMode currentReleaseMode = ReleaseMode.RELEASE;
  String currentUrl;
  bool isPlaying = false;

  AudioElement player;

  WrappedPlayer(this.playerId);

  Stream<Duration> get positionChanged => player.onTimeUpdate.map(
      (event) => Duration(milliseconds: (player.currentTime * 1000).toInt()));

  Stream<MediaError> get errorStream =>
      player.onError.map((event) => player.error);

  void setUrl(String url) {
    currentUrl = url;

    stop();
    recreateNode();
    if (isPlaying) {
      resume();
    }
  }

  Future<void> ensureReadyToPlay() async {
    var completer = Completer();
    var subError = player.onError.listen((error) {
      completer.completeError(Exception(player.error.message));
    });
    var sub = player.onCanPlayThrough.listen((event) {
      completer.complete();
    });
    try {
      await completer.future;
    } finally {
      sub?.cancel();
      subError?.cancel();
    }
  }

  void setVolume(double volume) {
    currentVolume = volume;
    player?.volume = volume;
  }

  double getCurrentPosition() {
    return player?.currentTime;
  }

  num getDuration() {
    var duration = player?.duration;
    if (duration == null ||
        duration == double.nan ||
        duration.toString() == 'NaN') {
      return 0;
    }
    return duration;
  }

  void seek(double position) {
    pausedAt = pausedAt != 0 ? position : 0;
    player?.currentTime = position;
  }

  void recreateNode() {
    if (currentUrl == null) {
      return;
    }
    player = AudioElement(currentUrl);
    player.loop = shouldLoop();
    player.volume = currentVolume;
  }

  bool shouldLoop() => currentReleaseMode == ReleaseMode.LOOP;

  void setReleaseMode(ReleaseMode releaseMode) {
    currentReleaseMode = releaseMode;
    player?.loop = shouldLoop();
  }

  void release() {
    _cancel();
    player = null;
  }

  void start(double position) {
    isPlaying = true;
    if (currentUrl == null) {
      return; // nothing to play yet
    }
    if (player == null) {
      recreateNode();
    }
    player.play();
    player.currentTime = position;
  }

  void resume() {
    start(pausedAt ?? 0);
  }

  void pause() {
    pausedAt = player.currentTime;
    _cancel();
  }

  void stop() {
    pausedAt = 0;
    _cancel();
  }

  void _cancel() {
    isPlaying = false;
    player?.pause();
    if (currentReleaseMode == ReleaseMode.RELEASE) {
      player = null;
    }
  }
}

class AudioplayersPlugin {
  final MethodChannel channel;

  // players by playerId
  Map<String, WrappedPlayer> players = {};

  StreamSubscription<Duration> _subPosition;

  StreamSubscription<MediaError> _subErrors;

  AudioplayersPlugin(this.channel);

  static void registerWith(Registrar registrar) {
    final MethodChannel channel = MethodChannel(
      'xyz.luan/audioplayers',
      const StandardMethodCodec(),
      registrar.messenger,
    );

    final AudioplayersPlugin instance = AudioplayersPlugin(channel);
    channel.setMethodCallHandler(instance.handleMethodCall);
  }

  WrappedPlayer getOrCreatePlayer(String playerId) {
    return players.putIfAbsent(playerId, () => WrappedPlayer(playerId));
  }

  Future<WrappedPlayer> setUrl(String playerId, String url) async {
    final WrappedPlayer player = getOrCreatePlayer(playerId);

    if (player.currentUrl == url) {
      return player;
    }

    try {
      player.setUrl(url);
      registerStreams(player);
      await player.ensureReadyToPlay();
    } catch (ex) {
      throw Exception('Error during player initialization: $ex');
    }
    return player;
  }

  ReleaseMode parseReleaseMode(String value) {
    return ReleaseMode.values.firstWhere((e) => e.toString() == value);
  }

  Future<dynamic> handleMethodCall(MethodCall call) async {
    final method = call.method;
    final playerId = call.arguments['playerId'];
    switch (method) {
      case 'setUrl':
        {
          final String url = call.arguments['url'];
          await setUrl(playerId, url);
          return 1;
        }
      case 'play':
        {
          final String url = call.arguments['url'];

          // TODO(luan) think about isLocal (is it needed or not)

          double volume = call.arguments['volume'] ?? 1.0;
          final double position = call.arguments['position'] ?? 0;
          // web does not care for the `stayAwake` argument

          final player = await setUrl(playerId, url);
          player.setVolume(volume);
          player.start(position);

          return 1;
        }
      case 'pause':
        {
          getOrCreatePlayer(playerId).pause();
          return 1;
        }
      case 'stop':
        {
          getOrCreatePlayer(playerId).stop();
          return 1;
        }
      case 'resume':
        {
          getOrCreatePlayer(playerId).resume();
          return 1;
        }
      case 'setVolume':
        {
          double volume = call.arguments['volume'] ?? 1.0;
          getOrCreatePlayer(playerId).setVolume(volume);
          return 1;
        }
      case 'getDuration':
        {
          final durationInSec = getOrCreatePlayer(playerId).getDuration();
          return (durationInSec * 1000).toInt();
        }
      case 'getCurrentPosition':
        {
          final positionInSec =
              getOrCreatePlayer(playerId).getCurrentPosition();
          return (positionInSec * 1000).toInt();
        }
      case 'setReleaseMode':
        {
          ReleaseMode releaseMode =
              parseReleaseMode(call.arguments['releaseMode']);
          getOrCreatePlayer(playerId).setReleaseMode(releaseMode);
          return 1;
        }
      case 'release':
        {
          getOrCreatePlayer(playerId).release();
          return 1;
        }
      case 'seek':
        double position = call.arguments['position'] ?? 0.0;
        getOrCreatePlayer(playerId).seek(position / 1000);
        return 1;
      case 'setPlaybackRate':
      default:
        throw PlatformException(
          code: 'Unimplemented',
          details:
              "The audioplayers plugin for web doesn't implement the method '$method'",
        );
    }
  }

  void registerStreams(WrappedPlayer player) {
    _subPosition?.cancel();
    _subPosition = player.positionChanged.listen((duration) {
      channel.invokeMethod('audio.onCurrentPosition',
          buildArguments(duration.inMilliseconds, player));
    });

    _subErrors?.cancel();
    _subErrors = player.errorStream.listen((mediaError) {
      channel.invokeMethod(
          'audio.onError', buildArguments(mediaError.message, player));
    });
  }

  Map<String, Object> buildArguments(Object value, WrappedPlayer player) {
    return {'value': value, 'playerId': player.playerId};
  }
}
