import React from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';
import {colors, radius} from './theme';

export type BadgeStatus = 'idle' | 'busy' | 'ok' | 'error';

const STATUS_COLOR: Record<BadgeStatus, string> = {
  idle: colors.gray,
  busy: colors.orange,
  ok: colors.green,
  error: colors.red,
};

interface StatusBadgeProps {
  label: string;
  status: BadgeStatus;
  detail?: string;
  /** Makes the badge a button with a trailing chevron. */
  onPress?: () => void;
  /** Read out after the label when the badge is a button. */
  accessibilityHint?: string;
  testID?: string;
}

/**
 * SocketStateBadge.swift: grey 8 pt-radius strip with a 10 pt status dot,
 * a medium 14 pt title, a secondary detail and a chevron.
 */
export function StatusBadge({
  label,
  status,
  detail,
  onPress,
  accessibilityHint,
  testID,
}: StatusBadgeProps) {
  return (
    <Pressable
      accessibilityRole={onPress ? 'button' : undefined}
      accessibilityHint={onPress ? accessibilityHint : undefined}
      disabled={!onPress}
      onPress={onPress}
      testID={testID}
      style={styles.badge}>
      <View style={[styles.dot, {backgroundColor: STATUS_COLOR[status]}]} />
      <Text style={styles.label}>{label}</Text>
      {detail ? <Text style={styles.detail}>{detail}</Text> : null}
      {onPress ? (
        <Text
          style={styles.chevron}
          accessibilityElementsHidden
          importantForAccessibility="no">
          {'\u203A'}
        </Text>
      ) : null}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 12,
    borderRadius: radius.badge,
    backgroundColor: colors.badgeBackground,
  },
  dot: {width: 10, height: 10, borderRadius: 5, marginRight: 8},
  label: {flexShrink: 1, fontSize: 14, fontWeight: '500', color: colors.text},
  detail: {
    flexShrink: 1,
    fontSize: 12,
    color: colors.secondary,
    marginLeft: 8,
  },
  // SocketStateBadge.swift:23: SF Symbol chevron.right at 12 pt ~ a 14 pt '›' glyph, pushed to the trailing edge
  chevron: {
    marginLeft: 'auto',
    paddingLeft: 8,
    fontSize: 14,
    color: colors.secondary,
  },
});
