import React from 'react';
import {Pressable, SafeAreaView, StyleSheet, Text, View} from 'react-native';
import {colors} from './theme';

interface HeaderAction {
  title: string;
  /** Spoken label when the visible title is a glyph plus text. */
  accessibilityLabel?: string;
  onPress: () => void;
  disabled?: boolean;
}

interface ScreenHeaderProps {
  title: string;
  /** Leading action, e.g. the back button of a pushed screen. */
  left?: HeaderAction;
  /** Trailing action, e.g. "Clear" (PushMessageLogView.swift:50). */
  right?: HeaderAction;
}

function Action({
  action,
  align,
}: {
  action?: HeaderAction;
  align: 'flex-start' | 'flex-end';
}) {
  if (!action) {
    return <View style={styles.side} />;
  }
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={action.accessibilityLabel}
      accessibilityState={{disabled: !!action.disabled}}
      disabled={action.disabled}
      onPress={action.onPress}
      style={[styles.side, {alignItems: align}]}>
      <Text
        numberOfLines={1}
        style={[styles.action, action.disabled && styles.disabled]}>
        {action.title}
      </Text>
    </Pressable>
  );
}

/**
 * Navigation bar of StartView.swift:195-204: opaque brand background, white
 * inline title.
 */
export function ScreenHeader({title, left, right}: ScreenHeaderProps) {
  return (
    <SafeAreaView style={styles.safe}>
      <View style={styles.bar}>
        <Action action={left} align="flex-start" />
        <Text accessibilityRole="header" numberOfLines={1} style={styles.title}>
          {title}
        </Text>
        <Action action={right} align="flex-end" />
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: {backgroundColor: colors.brand},
  bar: {
    height: 44,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
  },
  title: {
    flex: 1,
    textAlign: 'center',
    fontSize: 17,
    fontWeight: '600',
    color: colors.onBrand,
  },
  side: {minWidth: 72, justifyContent: 'center'},
  action: {fontSize: 17, color: colors.onBrand},
  disabled: {opacity: 0.4},
});
