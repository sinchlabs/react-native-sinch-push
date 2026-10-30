#!/usr/bin/env node
// scripts/ensure-generated.mjs — `prepack` guard for the generated protobuf code.
//
// The SDK ships generated TypeScript (src/generated), Swift
// (ios/SinchPushSocket/Generated) and Kotlin (android/src/main/wire). The public
// repository commits them, so there is nothing to do. The internal tree
// regenerates them from the pinned protos (`npm run proto:gen`, which needs
// scripts/fetch-protos.mjs and access to the proto repositories).
//
//   all outputs present                    -> nothing happens
//   missing, scripts/fetch-protos.mjs here -> runs `npm run proto:gen`, re-checks
//   missing, no fetch-protos.mjs           -> fails with the list of what is missing
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

// The files the code imports / compiles against; a regeneration that produced
// the full tree produced these.
const REQUIRED = [
  // TypeScript (src/api/*)
  'src/generated/sinch/push/sdk/v1beta1/sdk_pb.ts',
  'src/generated/sinch/push/events/v1beta1/events_pb.ts',
  'src/generated/sinch/push/v1beta1/resources_pb.ts',
  'src/generated/sinch/chat/sdk/v1alpha2/sdk_pb.ts',
  'src/generated/sinch/conversationapi/type/conversation_message_pb.ts',
  // Swift (ios/SinchPushSocket)
  'ios/SinchPushSocket/Generated/sinch/push/delivery/v1beta1/ws/websocket.pb.swift',
  'ios/SinchPushSocket/Generated/sinch/push/v1beta1/resources.pb.swift',
  // Kotlin / Wire (android/src/main/java/com/sinchpush/socket)
  'android/src/main/wire/sinch/push/delivery/v1beta1/ws/ClientFrame.kt',
  'android/src/main/wire/sinch/push/delivery/v1beta1/ws/ServerFrame.kt',
  'android/src/main/wire/sinch/push/v1beta1/resources/Platform.kt',
];

const missing = () => REQUIRED.filter((file) => !existsSync(path.join(root, file)));

let absent = missing();
if (absent.length === 0) {
  process.exit(0);
}

const list = (files) => files.map((file) => `  - ${file}`).join('\n');

if (!existsSync(path.join(root, 'scripts', 'fetch-protos.mjs'))) {
  console.error(
    `Generated protobuf code is missing:\n${list(absent)}\n\n` +
      'These files are committed to the repository; restore them (git checkout) instead of packing. ' +
      'Regenerating them needs the internal proto sources, which this tree does not have.'
  );
  process.exit(1);
}

console.log(`Generated protobuf code is missing (${absent.length} files); running "npm run proto:gen".`);
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const run = spawnSync(npm, ['run', 'proto:gen'], { cwd: root, stdio: 'inherit', shell: process.platform === 'win32' });
if (run.status !== 0) {
  console.error('"npm run proto:gen" failed.');
  process.exit(run.status ?? 1);
}

absent = missing();
if (absent.length > 0) {
  console.error(`"npm run proto:gen" finished but these files are still missing:\n${list(absent)}\n` +
      'proto:gen cannot produce the chat / conversation API code under src/generated; restore it from a backup or the published npm tarball.');
  process.exit(1);
}
