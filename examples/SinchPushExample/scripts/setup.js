// Creates the git-ignored local config files from their committed examples when
// they are missing. Never overwrites an existing file. Runs on postinstall and
// before start / ios / android; also available as `npm run setup`.
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const files = [
  ['src/config.example.ts', 'src/config.ts'],
  ['ios/Config.example.xcconfig', 'ios/Config.xcconfig'],
];

for (const [from, to] of files) {
  const target = path.join(root, to);
  if (!fs.existsSync(target)) {
    fs.copyFileSync(path.join(root, from), target);
    console.log(`[setup] created ${to} from ${from} - edit it before running the app`);
  }
}
