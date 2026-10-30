const path = require('path');
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');

// The library is consumed from the repo root (file: dependency -> symlink).
// Metro must watch it, and must resolve react / react-native / keychain from
// THIS app, not from the library's own (0.74) devDependencies.
const libRoot = path.resolve(__dirname, '../..');
const appModules = path.resolve(__dirname, 'node_modules');
const escape = p => p.replace(/[/\\]/g, '[/\\\\]');

const config = {
  watchFolders: [libRoot],
  resolver: {
    blockList: [
      new RegExp(`${escape(path.join(libRoot, 'node_modules'))}[/\\\\](react|react-native|react-native-keychain)[/\\\\].*`),
      new RegExp(`${escape(path.join(libRoot, 'examples'))}[/\\\\](?!SinchPushExample).*`),
    ],
    extraNodeModules: new Proxy(
      {},
      {get: (_, name) => path.join(appModules, String(name))},
    ),
    unstable_enableSymlinks: true,
    // The library depends on @bufbuild/protobuf subpaths (e.g. /wire) that are
    // only reachable through package.json "exports".
    unstable_enablePackageExports: true,
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
