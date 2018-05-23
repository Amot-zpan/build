// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
@Timeout(const Duration(minutes: 1))
@Tags(const ['integration'])

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:io/io.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import '../common/common.dart';

main() {
  setUpAll(() async {
    await d.dir('a', [
      await pubspec(
        'a',
        currentIsolateDependencies: [
          'build',
          'build_config',
          'build_runner',
          'build_test',
          'test',
        ],
        versionDependencies: {
          'build_web_compilers': 'any',
        },
      ),
      d.dir('test', [
        d.file('hello_test.dart', '''
import 'package:test/test.dart';
main() {
  test('hello', () {});
}'''),
      ]),
      d.dir('web', [
        d.file('main.dart', '''
main() {
  print('hello world');
}'''),
      ]),
    ]).create();

    await pubGet('a', offline: false);
  });

  tearDown(() async {
    await runPub('a', 'run', args: ['build_runner', 'clean']);
  });

  void expectOutput(String path, {@required bool exists}) {
    path =
        p.join(d.sandbox, 'a', '.dart_tool', 'build', 'generated', 'a', path);
    expect(new File(path).existsSync(), exists);
  }

  Future<int> runSingleBuild(String command, List<String> args,
      {StreamSink<String> stdoutSink}) async {
    var process = await startPub('a', 'run', args: args);
    var stdoutLines = process.stdout
        .transform(new Utf8Decoder())
        .transform(new LineSplitter())
        .asBroadcastStream();
    stdoutLines.listen((line) {
      stdoutSink?.add(line);
      printOnFailure(line);
    });
    var queue = new StreamQueue(stdoutLines);
    if (command == 'serve' || command == 'watch') {
      while (await queue.hasNext) {
        var nextLine = (await queue.next).toLowerCase();
        if (nextLine.contains('succeeded after')) {
          process.kill();
          await process.exitCode;
          return ExitCode.success.code;
        } else if (nextLine.contains('failed after')) {
          process.kill();
          await process.exitCode;
          return 1;
        }
      }
      throw new StateError('Build process exited without success or failure.');
    }
    var result = await process.exitCode;
    return result;
  }

  group('Building explicit output directories', () {
    testBasicBuildCommand(String command) {
      test('is supported by the $command command', () async {
        var args = ['build_runner', command, 'web'];
        expect(await runSingleBuild(command, args), ExitCode.success.code);
        expectOutput('web/main.dart.js', exists: true);
        expectOutput('test/hello_test.dart.js', exists: false);
      });
    }

    testBuildCommandWithOutput(String command) {
      test('works with -o and the $command command', () async {
        var outputDirName = 'foo';
        var args = [
          'build_runner',
          command,
          'web',
          '-o',
          'test:$outputDirName'
        ];
        expect(await runSingleBuild(command, args), ExitCode.success.code);
        expectOutput('web/main.dart.js', exists: true);
        expectOutput('test/hello_test.dart.js', exists: true);

        var outputDir = new Directory(p.join(d.sandbox, 'a', 'foo'));
        await outputDir.delete(recursive: true);
      });
    }

    for (var command in ['build', 'serve', 'watch']) {
      testBasicBuildCommand(command);
      testBuildCommandWithOutput(command);
    }

    test('is not supported for the test command', () async {
      var command = 'test';
      var args = ['build_runner', command, 'web'];
      expect(await runSingleBuild(command, args), ExitCode.usage.code);

      args.addAll(['--', '-p chrome']);
      expect(await runSingleBuild(command, args), ExitCode.usage.code);
    });
  });

  test('test builds only the test directory by default', () async {
    var command = 'test';
    var args = ['build_runner', command];
    expect(await runSingleBuild(command, args), ExitCode.success.code);
    expectOutput('web/main.dart.js', exists: false);
    expectOutput('test/hello_test.dart.js', exists: true);
  });

  test('Duplicate output directories give a nice error', () async {
    var command = 'build';
    var args = ['build_runner', command, '-o', 'web:build', '-o', 'test:build'];
    var stdoutController = new StreamController<String>();
    expect(
        await runSingleBuild(command, args, stdoutSink: stdoutController.sink),
        ExitCode.usage.code);
    expect(
        stdoutController.stream,
        emitsThrough(contains(
            'Invalid argument (--output): Duplicate output directories are not '
            'allowed, got: "web:build test:build"')));
    await stdoutController.close();
  });

  test('Build directories have to be top level dirs', () async {
    var command = 'build';
    var args = ['build_runner', command, '-o', 'foo/bar:build'];
    var stdoutController = new StreamController<String>();
    expect(
        await runSingleBuild(command, args, stdoutSink: stdoutController.sink),
        ExitCode.usage.code);
    expect(
        stdoutController.stream,
        emitsThrough(contains(
            'Invalid argument (--output): Input root can not be nested: '
            '"foo/bar:build"')));
    await stdoutController.close();
  });
}
