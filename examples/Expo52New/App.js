import { StatusBar } from 'expo-status-bar';
import { SafeAreaView } from 'react-native';
import DemoScreen from './DemoScreen';

export default function App() {
  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: '#0f1115' }}>
      <StatusBar style="light" />
      <DemoScreen />
    </SafeAreaView>
  );
}