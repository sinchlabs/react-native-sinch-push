import React from 'react';
import {
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import {Card} from './ui/Card';
import {ScreenHeader} from './ui/ScreenHeader';
import {colors, fonts, screenTitle, spacing} from './ui/theme';

export function ConfigMissingScreen({missing}: {missing: string[]}) {
  return (
    <View style={styles.root}>
      <StatusBar barStyle="light-content" backgroundColor={colors.brand} />
      <ScreenHeader title="Sinch Push" />
      <SafeAreaView style={styles.root}>
        <ScrollView contentContainerStyle={styles.content}>
          <Text style={styles.title}>Configuration missing</Text>
          <Card
            backgroundColor={colors.cardRose}
            title="Set these fields"
            description={
              <>
                Edit{' '}
                <Text style={styles.path}>
                  examples/SinchPushExample/src/config.ts
                </Text>{' '}
                (created from{' '}
                <Text style={styles.path}>src/config.example.ts</Text>) and set:
              </>
            }>
            {missing.map(field => (
              <Text key={field} style={styles.mono}>
                • {field}
              </Text>
            ))}
          </Card>
          <Text style={styles.text}>
            The ids are on the Sinch Build dashboard under "Sinch Push" in the
            sidebar. Save the file; Metro reloads the app. iOS also needs{' '}
            <Text style={styles.mono}>ios/Config.xcconfig</Text> (team, bundle
            id, App Group); see the README.
          </Text>
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: colors.background},
  content: {
    paddingHorizontal: spacing.screen,
    paddingVertical: spacing.screenVertical,
  },
  title: {...screenTitle, marginBottom: spacing.screenVertical},
  text: {fontSize: 12, color: colors.text, marginTop: spacing.card},
  path: {fontFamily: fonts.mono},
  mono: {
    fontFamily: fonts.mono,
    fontSize: 12,
    color: colors.text,
    marginVertical: 2,
  },
});
