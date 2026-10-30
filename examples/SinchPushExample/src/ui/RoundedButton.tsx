import React from 'react';
import {Pressable, StyleSheet, Text} from 'react-native';
import {colors, radius} from './theme';

interface RoundedButtonProps {
  title: string;
  onPress: () => void;
  disabled?: boolean;
  /** White button with a brand border (CardView `isBorderedButton`). */
  bordered?: boolean;
  /** Grows to share a row evenly with sibling buttons. */
  flex?: boolean;
  testID?: string;
}

/**
 * RoundedButtonStyle.swift: 32 pt high, 6 pt radius, bold 14 pt label. While
 * pressed or disabled the label and background drop to 30 % opacity.
 */
export function RoundedButton({
  title,
  onPress,
  disabled = false,
  bordered = false,
  flex = false,
  testID,
}: RoundedButtonProps) {
  const background = bordered ? colors.background : colors.brand;
  const foreground = bordered ? colors.brand : colors.onBrand;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{disabled}}
      disabled={disabled}
      onPress={onPress}
      testID={testID}
      style={({pressed}) => [
        styles.button,
        {
          backgroundColor: background,
          borderColor: bordered ? colors.brand : background,
          opacity: disabled || pressed ? 0.3 : 1,
        },
        flex && styles.flex,
      ]}>
      <Text style={[styles.label, {color: foreground}]}>{title}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    height: 32,
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: radius.button,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  flex: {flex: 1},
  label: {fontSize: 14, fontWeight: '700'},
});
