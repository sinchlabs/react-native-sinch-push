import React, {ReactNode} from 'react';
import {StyleProp, StyleSheet, Text, View, ViewStyle} from 'react-native';
import {colors, radius} from './theme';

interface CardProps {
  /** Pastel background, one of the DemoApp card colours. */
  backgroundColor: string;
  title: string;
  /** A string, or nested `<Text>` for inline spans such as monospace paths. */
  description?: ReactNode;
  /** Outer style, e.g. the gap below the card. */
  style?: StyleProp<ViewStyle>;
  children?: ReactNode;
}

/** CardView.swift: 16 pt padding, 14 pt radius, no border or shadow. */
export function Card({
  backgroundColor,
  title,
  description,
  style,
  children,
}: CardProps) {
  return (
    <View style={[styles.card, {backgroundColor}, style]}>
      <Text style={styles.title}>{title}</Text>
      {description ? (
        <Text style={styles.description}>{description}</Text>
      ) : null}
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {padding: 16, borderRadius: radius.card},
  // CardView.swift:20-22
  title: {
    fontSize: 24,
    fontWeight: '500',
    color: colors.text,
    marginBottom: 8,
  },
  // CardView.swift:26-31
  description: {fontSize: 12, color: colors.text, marginBottom: 8},
});
