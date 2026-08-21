const path = require('path');
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');

/**
 * Metro configuration
 * https://reactnative.dev/docs/metro
 *
 * @type {import('metro-config').MetroConfig}
 */
const repoRoot = path.resolve(__dirname, '../..');

const config = {
  resolver: {
    unstable_enableSymlinks: true,
    unstable_enablePackageExports: true,
    nodeModulesPaths: [path.resolve(repoRoot, 'node_modules')],
  },
  watchFolders: [repoRoot],
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
