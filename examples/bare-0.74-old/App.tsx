import React from 'react';
import { SafeAreaView, StatusBar } from 'react-native';
import { DemoScreen } from './src/DemoScreen';

function App(): React.JSX.Element {
  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: '#0f1115' }}>
      <StatusBar barStyle="light-content" backgroundColor="#0f1115" />
      <DemoScreen />
    </SafeAreaView>
  );
}

export default App;