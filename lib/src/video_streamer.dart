import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:flutter_video_cache/src/consts.dart';
import 'package:flutter_video_cache/src/downloader_manager.dart';
import 'package:flutter_video_cache/src/media_metadata_utils.dart';
import 'package:flutter_video_cache/src/models/exceptions/file_not_exist_exception.dart';
import 'package:flutter_video_cache/src/models/exceptions/video_streamer_exception.dart';
import 'package:flutter_video_cache/src/models/media_metadata.dart';
import 'package:flutter_video_cache/src/models/playable_interface.dart';
import 'package:flutter_video_cache/src/utils.dart';

class VideoStream<T extends PlayableInterface> {

  /// A playable object that can be played/paused depends on data status on [dataFile]
  final T playable;

  /// The data file where the video/audio is stored
  File? _dataFile;

  /// The file downloader manager
  final DownloadManager _downloaderManager = DownloadManager.instance;

  /// The total duration of the media
  int _mediaDurationInSeconds = 0;

  /// The number of seconds of the loaded media inside [_dataFile]
  int _loadedMediaDurationInSeconds = 0;

  /// True if the media is initialized
  ///
  /// [_dataFile] is created
  bool _mediaInitialized = false;


  /// True if the data source is initialized
  bool _dataSourceInitialized = false;

  /// A timer to check if the media can start playing
  Timer? playingCheckTimer;

  /// True if the video/audio can start playing
  ///
  /// true if we can read metadata of [_dataFile]
  bool _canStartPlaying = false;

  /// True if [play] is called and it's paused due to not enough data
  bool _waitingForData = false;

  /// True if is precaching data
  bool _isPreCaching = false;

  /// The total length of [_dataFile]
  double _fileTotalLength = 0;

  /// A list of callback that should be called by [onProgress]
  final List<void Function({required int percentage,required int loadedSeconds,required int loadedBytes})> _onProgressCallbacks = [];

  Completer<void>? _initCompleter;

  /// The [_downloaderManager] task key
  late final String cacheKey;

  /// The media remote url
  final String url;

  VideoStream({required this.url,required this.playable, String? cacheKey}){
    if(cacheKey == null){
      this.cacheKey = url;
    } else {
      this.cacheKey = cacheKey;
    }

  }




  /// Returns true if the playable is initialized & _mediaInitialized & _canStartPlaying
  bool get isInitialized => playable.isInitialized && _mediaInitialized && _canStartPlaying;



  /// Sets the data source for media playback asynchronously.
  ///
  /// This method ensures that the media is pre-cached before setting the data source,
  /// if the media hasn't been initialized yet. It then sets the data source using
  /// the file path obtained from [_dataFile].
  ///
  /// Note: This method assumes the existence of [_mediaInitialized], [preCache],
  /// [playable], and [_dataFile].
  ///
  /// Throws: May throw exceptions if there are issues during pre-caching or setting the data source.
  Future<void> setDataSource() async {
    // If media is not initialized, pre-cache it before setting the data source.
    if (!_mediaInitialized) {
      await preCache();
    }

    // Set the data source for media playback using the file path.
    await playable.setDataSource(_dataFile!.path);
    _dataSourceInitialized = true;
  }




  /// Prepares the video/audio to be played and start/resume precaching video
  Future<void> initialize() async {
    if(_mediaInitialized && _dataSourceInitialized) {
      await playable.initialize();
      if(!_canStartPlaying){
        _initCompleter = Completer();
        return _initCompleter!.future;
      }
    }
    throw const VideoStreamerException('cannot initialize a video streamer without initializing media and data source');
  }

  /// Start pre-caching the video/audio
  Future<void> preCache() async {
    _isPreCaching = true;
    // call [_downloaderManager.startDownload(url,onProgress, cacheKey)] and get filePath
    String filePath = await _downloaderManager.startDownload(url, onProgress, key: cacheKey);
    // init [_dataFile]
    _dataFile == null ? _dataFile = File(filePath) : null;
    // check if [_dataFile] exists

    if(!_dataFile!.existsSync()) {
      throw const FileNotExistsException('File should exist and created by the downloadManager');
    }
    _mediaInitialized = true;
  }

  /// Pause pre-caching the video/audio
  void pausePreCaching(){
    _isPreCaching = false;
    _downloaderManager.pauseDownload(cacheKey);
  }

  /// Resume pre-caching the video/audio
  void resumePreCaching(){
    _isPreCaching = true;
    _downloaderManager.resumeDownload(cacheKey);
  }


  /// Pre-caches data for a specified duration in seconds.
  /// This method asynchronously pre-caches data and adds a callback to [_onProgressCallbacks].
  /// The callback checks if the required number of seconds is obtained to stop pre-caching
  /// by calling [pausePreCachingVideo].
  ///
  /// Parameters:
  ///   - [seconds] : The duration in seconds for pre-caching to continue.
  ///
  /// Returns: A [Future] with no value.
  Future<void> preCacheNSeconds(int seconds) async {
    await preCache();
    // add a callback to [_onProgressCallbacks] to check if the number of seconds are obtained to stop the pre-caching by calling [pausePreCachingVideo]
    int index = _onProgressCallbacks.length;
    _onProgressCallbacks.add(({required int percentage, required int loadedSeconds, required int loadedBytes}) {
      if(loadedSeconds >= seconds ){
        pausePreCaching();
        _onProgressCallbacks.removeAt(index);
      }
    });
  }

  /// Plays the video
  Future<void> play() async {
    if(_canStartPlaying && !_waitingForData) {
      _setFutureCheckForEnoughDataTimer();
      preCache();
      playable.play();
    } else {
      //set _needToPlay to true
      _waitingForData = true;
      preCache();
    }
  }

  void pause() {
    /// set _needToPlay to false
    _waitingForData = false;
    playingCheckTimer?.cancel();
    playable.pause();
  }

  /// Sets up a timer to periodically check for enough data during media playback.
  /// The timer is started when playback begins and is paused if the current position
  /// exceeds [_loadedMediaDurationInSeconds - mediaThreshHoldInSeconds].
  ///
  /// This method uses a [Timer.periodic] to check the conditions periodically and
  /// pauses the media playback if necessary. Additionally, it sets the [_waitingForData]
  /// flag to true when pausing due to insufficient data.
  ///
  /// Note: This method is intended for internal use and assumes the existence of
  /// [playable], [_loadedMediaDurationInSeconds], [mediaThreshHoldInSeconds], and [_waitingForData].
  ///
  /// Throws: Throws an exception if there is an issue retrieving the current playable position.
  void _setFutureCheckForEnoughDataTimer() async {

      int currentPlayablePosition = await playable.getCurrentPosition();

      /// set timer when start playing and pause it if current seconds > [_loadedMediaDurationInSeconds] - [mediaThreshHoldInSeconds]
      playingCheckTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        int currentPlayablePosition = await playable.getCurrentPosition();
        if(_loadedMediaDurationInSeconds < currentPlayablePosition + mediaThreshHoldInSeconds && playable.isPlaying) {
          playable.pause();
          _waitingForData = true;
          timer.cancel();
          return;
        }
        timer.cancel();
        _setFutureCheckForEnoughDataTimer();
      });

  }


  /// Registers a callback to be invoked during the progress of media playback.
  ///
  /// Parameters:
  ///   - [callback] : A callback function that takes percentage, loaded seconds, and loaded bytes.
  ///
  /// This method adds the provided [callback] to the list of progress callbacks.
  void registerOnProgressCallback(void Function({required int percentage,required int loadedSeconds,required int loadedBytes}) callback) {
    _onProgressCallbacks.add(callback);
  }

  /// Removes a previously registered callback from the list of progress callbacks.
  ///
  /// Parameters:
  ///   - [callback] : The callback function to be removed.
  ///
  /// This method removes the specified [callback] from the list of progress callbacks.
  void removeCallback(void Function({required int percentage,required int loadedSeconds,required int loadedBytes}) callback){
    _onProgressCallbacks.removeWhere((element) => element == callback);
  }

  /// Callback method invoked during the progress of file download.
  ///
  /// Parameters:
  ///   - [progress] : The progress value indicating the advancement of file download %.
  ///
  /// Note: This method updates various internal variables, checks for metadata,
  /// and invokes registered progress callbacks.
  void onProgress(int progress) async {

    if(progress == 0) return;

    log('on Progress $progress');


    // If playback hasn't started yet, search for metadata in the file.
    if (!_canStartPlaying) {
      // Retrieve metadata from the file.
      MediaMetadata? metadata = await MediaMetadataUtils.retrieveMetadataFromFile(_dataFile!);
      log('metadata from plugin: $metadata');

      // If metadata is unavailable, return early.
      if (metadata == null) {
        return;
      }

      // Set _canStartPlaying to true and update _mediaDurationInSeconds from metadata.
      _canStartPlaying = true;
      _mediaDurationInSeconds = metadata.duration;
      _fileTotalLength = metadata.fileSize.toDouble();
      log('media duration: $_mediaDurationInSeconds, file length: $_fileTotalLength');

      // Check if _initCompleter is not null, complete it with null.
      if (_initCompleter != null) {
        log('>>> _initCompleter');
        _initCompleter!.complete();
        _initCompleter = null;
      }
    }

    // Update [_loadedMediaDurationInSeconds] based on the progress.
    _loadedMediaDurationInSeconds = _mediaDurationInSeconds! * progress ~/ 100;

    // Get the current playable position.
    int currentPlayablePosition = await playable.getCurrentPosition();


    log('_loadedMediaDurationInSeconds $_loadedMediaDurationInSeconds, currentPlayablePosition $currentPlayablePosition');

    // Check if waiting for data and if it's time to resume playback.
    if (_waitingForData) {
      if (_loadedMediaDurationInSeconds > currentPlayablePosition + mediaThreshHoldInSeconds) {
        _waitingForData = false;
        play();
      }
    }

    // Invoke registered progress callbacks.
    for (var callback in _onProgressCallbacks) {
      callback(percentage: progress, loadedSeconds: _loadedMediaDurationInSeconds, loadedBytes: _fileTotalLength.toInt());
    }
  }





}