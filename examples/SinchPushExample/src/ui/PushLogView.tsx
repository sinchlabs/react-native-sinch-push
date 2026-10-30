import React from 'react';
import {StyleSheet, Text, View} from 'react-native';
import {LogLine, ReceivedMessage} from '../log';
import {colors, fonts, radius} from './theme';

/** PushMessageLogView.swift:23-25: blue for APNs, green for the relay. */
const channelColor = (channel: string) =>
  channel === 'APNs' ? colors.blue : colors.green;

/** Translucent tint, like `Color.blue.opacity(0.25)`. */
const tint = (hex: string) => `${hex}40`;

export function PushLogRow({message}: {message: ReceivedMessage}) {
  return (
    <View style={styles.row}>
      <View style={styles.header}>
        <Text
          style={[
            styles.channel,
            {backgroundColor: tint(channelColor(message.channel))},
          ]}>
          {message.channel}
        </Text>
        <Text style={styles.event}>{message.event}</Text>
        <View style={styles.spacer} />
        <Text style={styles.time}>{message.time}</Text>
      </View>
      <Text style={styles.title}>{message.title || '(no title)'}</Text>
      {message.body ? <Text style={styles.body}>{message.body}</Text> : null}
      <Text selectable style={styles.messageId}>
        {message.messageId ?? 'no message id'}
      </Text>
    </View>
  );
}

interface PushLogViewProps {
  messages: ReceivedMessage[];
  events: LogLine[];
}

/**
 * PushMessageLogView.swift: plain list, one row per received push (channel
 * pill, event, monospaced time; title, body, selectable message id), "No
 * messages yet" when empty. The delivery-event lines follow as compact rows.
 */
export function PushLogView({messages, events}: PushLogViewProps) {
  return (
    <View>
      <Text style={styles.sectionTitle}>
        {`Received messages (${messages.length})`}
      </Text>
      <Text style={styles.hint}>
        Foreground only: what onPushReceiveHandler delivers. Background / killed
        pushes show up as system notifications.
      </Text>
      {messages.length === 0 ? (
        <Text style={styles.empty}>No messages yet</Text>
      ) : (
        messages.map(m => <PushLogRow key={m.key} message={m} />)
      )}

      <Text style={styles.sectionTitle}>Delivery-event log</Text>
      <Text style={styles.hint}>
        Local events only. DELIVERED reports for pushes that arrive in the
        background or with the app killed are sent natively by the SDK (iOS
        Notification Service Extension / background wake, Android FCM service);
        the SDK exposes no JS event for them.
      </Text>
      {events.length === 0 ? (
        <Text style={styles.empty}>No events yet</Text>
      ) : (
        events.map(e => (
          <View key={e.key} style={styles.eventRow}>
            <Text style={styles.time}>{e.time}</Text>
            <Text style={styles.eventText}>{e.text}</Text>
          </View>
        ))
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  sectionTitle: {
    fontSize: 14,
    fontWeight: '500',
    color: colors.text,
    marginTop: 8,
    marginBottom: 8,
  },
  hint: {fontSize: 12, color: colors.secondary, marginBottom: 8},
  empty: {
    fontSize: 14,
    color: colors.secondary,
    textAlign: 'center',
    paddingVertical: 24,
  },
  // PushMessageLogView.swift:19 VStack(spacing: 4) in a plain List row
  row: {
    paddingVertical: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.separator,
  },
  header: {flexDirection: 'row', alignItems: 'center', marginBottom: 4},
  spacer: {flex: 1},
  channel: {
    fontSize: 11,
    fontWeight: '700',
    color: colors.text,
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: radius.pill,
    overflow: 'hidden',
  },
  event: {fontSize: 12, color: colors.secondary, marginLeft: 8},
  time: {fontSize: 12, fontFamily: fonts.mono, color: colors.secondary},
  title: {fontSize: 15, fontWeight: '500', color: colors.text, marginBottom: 4},
  body: {fontSize: 14, color: colors.text, marginBottom: 4},
  messageId: {fontSize: 11, fontFamily: fonts.mono, color: colors.secondary},
  eventRow: {
    flexDirection: 'row',
    paddingVertical: 4,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.separator,
  },
  eventText: {
    flex: 1,
    fontSize: 12,
    color: colors.text,
    marginLeft: 8,
  },
});
