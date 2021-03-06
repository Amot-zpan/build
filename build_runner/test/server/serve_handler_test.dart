// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'package:build_runner/build_runner.dart';
import 'package:build_runner_core/build_runner_core.dart';
import 'package:build_runner_core/src/asset_graph/graph.dart';
import 'package:build_runner_core/src/asset_graph/node.dart';
import 'package:build_runner_core/src/asset_graph/optional_output_tracker.dart';
import 'package:build_runner_core/src/generate/performance_tracker.dart';
import 'package:build_runner/src/generate/watch_impl.dart';
import 'package:build_runner/src/server/server.dart';

import 'package:_test_common/common.dart';
import 'package:_test_common/package_graphs.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  ServeHandler serveHandler;
  InMemoryRunnerAssetReader reader;
  MockWatchImpl watchImpl;
  AssetGraph assetGraph;

  setUp(() async {
    reader = InMemoryRunnerAssetReader();
    final packageGraph = buildPackageGraph({rootPackage('a'): []});
    assetGraph = await AssetGraph.build([], Set(), Set(), packageGraph, reader);
    watchImpl = MockWatchImpl(
        FinalizedReader(
            reader, assetGraph, OptionalOutputTracker(assetGraph, [], []), 'a'),
        packageGraph,
        assetGraph);
    serveHandler = createServeHandler(watchImpl);
    watchImpl
        .addFutureResult(Future.value(BuildResult(BuildStatus.success, [])));
  });

  void _addSource(String id, String content, {bool deleted = false}) {
    var node = makeAssetNode(id, [], computeDigest('a'));
    if (deleted) {
      node.deletedBy.add(node.id.addExtension('.post_anchor.1'));
    }
    assetGraph.add(node);
    reader.cacheStringAsset(node.id, content);
  }

  test('can get handlers for a subdirectory', () async {
    _addSource('a|web/index.html', 'content');
    var response = await serveHandler.handlerFor('web')(
        Request('GET', Uri.parse('http://server.com/index.html')));
    expect(await response.readAsString(), 'content');
  });

  test('caching with etags works', () async {
    _addSource('a|web/index.html', 'content');
    var handler = serveHandler.handlerFor('web');
    var requestUri = Uri.parse('http://server.com/index.html');
    var firstResponse = await handler(Request('GET', requestUri));
    var etag = firstResponse.headers[HttpHeaders.etagHeader];
    expect(etag, isNotNull);
    expect(firstResponse.statusCode, HttpStatus.ok);
    expect(await firstResponse.readAsString(), 'content');

    var cachedResponse = await handler(Request('GET', requestUri,
        headers: {HttpHeaders.ifNoneMatchHeader: etag}));
    expect(cachedResponse.statusCode, HttpStatus.notModified);
    expect(await cachedResponse.readAsString(), isEmpty);
  });

  test('throws if you pass a non-root directory', () {
    expect(() => serveHandler.handlerFor('web/sub'), throwsArgumentError);
  });

  group('build failures', () {
    setUp(() async {
      _addSource('a|web/index.html', '');
      assetGraph.add(GeneratedAssetNode(
        makeAssetId('a|web/main.ddc.js'),
        builderOptionsId: null,
        phaseNumber: null,
        state: NodeState.upToDate,
        isHidden: false,
        wasOutput: true,
        isFailure: true,
        primaryInput: null,
      ));
      watchImpl
          .addFutureResult(Future.value(BuildResult(BuildStatus.failure, [])));
    });

    test('serves successful assets', () async {
      var response = await serveHandler.handlerFor('web')(
          Request('GET', Uri.parse('http://server.com/index.html')));

      expect(response.statusCode, HttpStatus.ok);
    });

    test('rejects requests for failed assets', () async {
      var response = await serveHandler.handlerFor('web')(
          Request('GET', Uri.parse('http://server.com/main.ddc.js')));

      expect(response.statusCode, HttpStatus.internalServerError);
    });

    test('logs rejected requests', () async {
      expect(
          Logger.root.onRecord,
          emitsThrough(predicate<LogRecord>((record) =>
              record.message.contains('main.ddc.js') &&
              record.level == Level.WARNING)));
      await serveHandler.handlerFor('web', logRequests: true)(
          Request('GET', Uri.parse('http://server.com/main.ddc.js')));
    });
  });

  test('logs requests if you ask it to', () async {
    _addSource('a|web/index.html', 'content');
    expect(
        Logger.root.onRecord,
        emitsThrough(predicate<LogRecord>((record) =>
            record.message.contains('index.html') &&
            record.level == Level.INFO)));
    await serveHandler.handlerFor('web', logRequests: true)(
        Request('GET', Uri.parse('http://server.com/index.html')));
  });

  group(r'/$perf', () {
    test('serves some sort of page if enabled', () async {
      var tracker = BuildPerformanceTracker()..start();
      var actionTracker = tracker.startBuilderAction(
          makeAssetId('a|web/a.txt'), 'test_builder');
      actionTracker.track(() {}, 'SomeLabel');
      tracker.stop();
      actionTracker.stop();
      watchImpl.addFutureResult(Future.value(
          BuildResult(BuildStatus.success, [], performance: tracker)));
      await Future(() {});
      var response = await serveHandler.handlerFor('web')(
          Request('GET', Uri.parse(r'http://server.com/$perf')));

      expect(response.statusCode, HttpStatus.ok);
      expect(await response.readAsString(),
          allOf(contains('test_builder:a|web/a.txt'), contains('SomeLabel')));
    });

    test('serves an error page if not enabled', () async {
      watchImpl.addFutureResult(Future.value(BuildResult(
          BuildStatus.success, [],
          performance: BuildPerformanceTracker.noOp())));
      await Future(() {});
      var response = await serveHandler.handlerFor('web')(
          Request('GET', Uri.parse(r'http://server.com/$perf')));

      expect(response.statusCode, HttpStatus.ok);
      expect(await response.readAsString(), contains('--track-performance'));
    });
  });

  group('build updates', () {
    test('injects client code if enabled', () async {
      _addSource('a|web/some.js', entrypointExtensionMarker + '\nalert(1)');
      var response = await serveHandler.handlerFor('web', liveReload: true)(
          Request('GET', Uri.parse('http://server.com/some.js')));
      expect(await response.readAsString(), contains('\$livereload'));
    });

    test('doesn\'t inject client code if disabled', () async {
      _addSource('a|web/some.js', entrypointExtensionMarker + '\nalert(1)');
      var response = await serveHandler.handlerFor('web', liveReload: false)(
          Request('GET', Uri.parse('http://server.com/some.js')));
      expect(await response.readAsString(), isNot(contains('\$livereload')));
    });

    test('doesn\'t inject client code in non-js files', () async {
      _addSource('a|web/some.html', entrypointExtensionMarker + '\n<br>some');
      var response = await serveHandler.handlerFor('web', liveReload: true)(
          Request('GET', Uri.parse('http://server.com/some.html')));
      expect(await response.readAsString(), isNot(contains('\$livereload')));
    });

    test('doesn\'t inject client code in non-marked files', () async {
      _addSource('a|web/some.js', 'alert(1)');
      var response = await serveHandler.handlerFor('web', liveReload: true)(
          Request('GET', Uri.parse('http://server.com/some.js')));
      expect(await response.readAsString(), isNot(contains('\$livereload')));
    });

    test('expect websocket connection if enabled', () async {
      _addSource('a|web/index.html', 'content');
      expect(
          serveHandler.handlerFor('web', liveReload: true)(
              Request('GET', Uri.parse('ws://server.com/'),
                  headers: {
                    'Connection': 'Upgrade',
                    'Upgrade': 'websocket',
                    'Sec-WebSocket-Version': '13',
                    'Sec-WebSocket-Key': 'abc',
                  },
                  onHijack: (f) {})),
          throwsA(TypeMatcher<HijackException>()));
    });

    test('reject websocket connection if disabled', () async {
      _addSource('a|web/index.html', 'content');
      var response = await serveHandler.handlerFor('web', liveReload: false)(
          Request('GET', Uri.parse('ws://server.com/'), headers: {
        'Connection': 'Upgrade',
        'Upgrade': 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': 'abc',
      }));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'content');
    });

    group('WebSocket handler', () {
      BuildUpdatesWebSocketHandler buildUpdatesWebSocketHandler;
      Function createMockConection;

      // client to server stream controlllers
      StreamController<List<int>> c2sController1;
      StreamController<List<int>> c2sController2;
      // server to client stream controlllers
      StreamController<List<int>> s2cController1;
      StreamController<List<int>> s2cController2;

      WebSocketChannel clientChannel1;
      WebSocketChannel clientChannel2;
      WebSocketChannel serverChannel1;
      WebSocketChannel serverChannel2;

      setUp(() {
        var mockHandlerFactory = (Function onConnect, {protocols}) {
          createMockConection =
              (WebSocketChannel serverChannel) => onConnect(serverChannel, '');
        };
        buildUpdatesWebSocketHandler =
            BuildUpdatesWebSocketHandler(mockHandlerFactory);

        c2sController1 = StreamController<List<int>>();
        s2cController1 = StreamController<List<int>>();
        serverChannel1 = WebSocketChannel(
            StreamChannel(c2sController1.stream, s2cController1.sink),
            serverSide: true);
        clientChannel1 = WebSocketChannel(
            StreamChannel(s2cController1.stream, c2sController1.sink),
            serverSide: false);

        c2sController2 = StreamController<List<int>>();
        s2cController2 = StreamController<List<int>>();
        serverChannel2 = WebSocketChannel(
            StreamChannel(c2sController2.stream, s2cController2.sink),
            serverSide: true);
        clientChannel2 = WebSocketChannel(
            StreamChannel(s2cController2.stream, c2sController2.sink),
            serverSide: false);
      });

      tearDown(() {
        c2sController1.close();
        s2cController1.close();
        c2sController2.close();
        s2cController2.close();
      });

      test('emmits a message to all listners', () async {
        expect(clientChannel1.stream, emitsInOrder(['update', emitsDone]));
        expect(clientChannel2.stream, emitsInOrder(['update', emitsDone]));
        createMockConection(serverChannel1);
        createMockConection(serverChannel2);
        buildUpdatesWebSocketHandler.emitUpdateMessage(null);
        await clientChannel1.sink.close();
        await clientChannel2.sink.close();
      });

      test('deletes listners on disconect', () async {
        expect(clientChannel1.stream,
            emitsInOrder(['update', 'update', emitsDone]));
        expect(clientChannel2.stream, emitsInOrder(['update', emitsDone]));
        createMockConection(serverChannel1);
        createMockConection(serverChannel2);
        buildUpdatesWebSocketHandler.emitUpdateMessage(null);
        await clientChannel2.sink.close();
        buildUpdatesWebSocketHandler.emitUpdateMessage(null);
        await clientChannel1.sink.close();
      });
    });
  });
}

class MockWatchImpl implements WatchImpl {
  @override
  final AssetGraph assetGraph;

  Future<BuildResult> _currentBuild;
  @override
  Future<BuildResult> get currentBuild => _currentBuild;
  @override
  set currentBuild(newValue) => throw UnsupportedError('unsupported!');

  final _futureBuildResultsController = StreamController<Future<BuildResult>>();
  final _buildResultsController = StreamController<BuildResult>();

  @override
  get buildResults => _buildResultsController.stream;
  @override
  set buildResults(_) => throw UnsupportedError('unsupported!');

  @override
  final PackageGraph packageGraph;

  @override
  final FinalizedReader reader;

  void addFutureResult(Future<BuildResult> result) {
    _futureBuildResultsController.add(result);
  }

  MockWatchImpl(this.reader, this.packageGraph, this.assetGraph) {
    var firstBuild = Completer<BuildResult>();
    _currentBuild = firstBuild.future;
    _futureBuildResultsController.stream.listen((futureBuildResult) {
      if (!firstBuild.isCompleted) {
        firstBuild.complete(futureBuildResult);
      }
      _currentBuild = _currentBuild.then((_) => futureBuildResult);
      _currentBuild.then(_buildResultsController.add);
    });
  }

  @override
  Future<Null> get ready => Future.value(null);
}
