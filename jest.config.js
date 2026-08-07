module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  testMatch: ['<rootDir>/__tests__/**/*.test.ts'],
  // Use the test-specific tsconfig (verbatimModuleSyntax off, CommonJS emit)
  // since the project tsconfig.json has verbatimModuleSyntax: true + module:
  // ESNext which clashes with ts-jest's CJS output.
  transform: {
    '^.+\\.tsx?$': ['ts-jest', { tsconfig: '<rootDir>/tsconfig.test.json', isolatedModules: true }],
  },
  // Stub native packages at the test boundary; generated output is real.
  moduleNameMapper: {
    '^react-native$': '<rootDir>/__tests__/__mocks__/react-native.ts',
    '^react-native-keychain$': '<rootDir>/__tests__/__mocks__/react-native-keychain.ts',
  },
};
